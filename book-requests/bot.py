"""
book-requests - Discord request queue for the Calibre-Web-Automated library

  /book title:<search> [notes]            ask for a book (Open Library autocomplete) - all family sees

  Admin-only (/books is hidden from anyone without Administrator):
  /books list                             recent requests from everyone
  /books send title:<library search>      email a library book to a Kindle
  /books kindle [email] [user]            set/show a Kindle address (DEFAULT_KINDLE covers everyone else)
  /books link request:<..> title:<..>     match a request to a library book by hand

Flow: a request DMs each approver a card with Approve / Decline buttons and DMs the
requester a card; both are edited as the status moves.
Fetching the book is manual: drop it in the CWA ingest folder. The bot polls the
Calibre metadata.db, posts every new book to BOOKS_CHANNEL_ID, and when one matches
an open request it marks it fulfilled, emails the EPUB to the requester's Kindle
(AUTO_SEND) and DMs them that it's on the way - the requester never has to press anything.

Problems (SMTP failures, files stuck in ingest, requests approved but not filled
after STALE_DAYS) go to WARN_CHANNEL_ID. Each poll pings HC_PING_URL.

All config comes from environment variables (see CONFIG below); state is a small
sqlite DB in /data.
"""

import asyncio
import difflib
import logging
import os
import re
import smtplib
import sqlite3
import time
import unicodedata
from email.message import EmailMessage
from pathlib import Path

import aiohttp
import discord
from discord import app_commands
from discord.ext import tasks

# ----------------------------- CONFIG ---------------------------------------
def env_ids(name):
    return {int(x) for x in os.environ.get(name, "").replace(" ", "").split(",") if x}

TOKEN = os.environ["DISCORD_BOT_TOKEN"]
GUILD_ID = int(os.environ["GUILD_ID"])
BOOKS_CHANNEL_ID = int(os.environ["BOOKS_CHANNEL_ID"])         # "new in the library" + fallback for closed DMs
WARN_CHANNEL_ID = int(os.environ["WARN_CHANNEL_ID"])
APPROVER_IDS = env_ids("APPROVER_IDS")                         # Discord user ids
ALLOWED_ROLE_IDS = env_ids("ALLOWED_ROLE_IDS")                 # who may use /book (approvers always can)

LIBRARY = Path(os.environ.get("LIBRARY_DIR", "/calibre-library"))
INGEST = Path(os.environ.get("INGEST_DIR", "/cwa-book-ingest"))
DB_PATH = Path(os.environ.get("STATE_DB", "/data/book-requests.db"))
CWA_URL = os.environ.get("CWA_PUBLIC_URL", "")                 # optional: link "new book" posts there

SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
SMTP_FROM = os.environ.get("SMTP_FROM") or SMTP_USER           # must be on Amazon's approved sender list
DEFAULT_KINDLE = os.environ.get("DEFAULT_KINDLE", "")          # used for anyone without their own address
AUTO_SEND = os.environ.get("AUTO_SEND", "true").lower() == "true"  # email a requested book as soon as it lands

HC_PING_URL = os.environ.get("HC_PING_URL", "")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "120"))
STALE_DAYS = int(os.environ.get("STALE_DAYS", "7"))
INGEST_STUCK_MINUTES = int(os.environ.get("INGEST_STUCK_MINUTES", "30"))
MATCH_RATIO = float(os.environ.get("MATCH_RATIO", "0.85"))
KINDLE_MAX_BYTES = 50 * 1024 * 1024                            # Send to Kindle email limit
# Amazon's Send to Kindle takes EPUB (converted on their side) and PDF - not MOBI/AZW3
SEND_FORMATS = ("EPUB", "PDF")
# -----------------------------------------------------------------------------

log = logging.getLogger("book-requests")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

OPEN, APPROVED, DECLINED, FULFILLED, CANCELLED = "pending", "approved", "declined", "fulfilled", "cancelled"
STATUS_TEXT = {
    OPEN: ("🕓", "Waiting for approval"),
    APPROVED: ("👍", "Approved - on the way"),
    DECLINED: ("✖️", "Declined"),
    FULFILLED: ("✅", "In the library"),
    CANCELLED: ("🗑️", "Cancelled"),
}
STATUS_COLOR = {OPEN: 0x95A5A6, APPROVED: 0x3498DB, DECLINED: 0xE74C3C, FULFILLED: 0x2ECC71, CANCELLED: 0x7F8C8D}


# ----------------------------- state DB -------------------------------------
def state():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db

def init_state():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with state() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            work_key TEXT, title TEXT NOT NULL, author TEXT, year INTEGER, cover_id INTEGER,
            notes TEXT, status TEXT NOT NULL, reason TEXT,
            card_message_id INTEGER, dm_channel_id INTEGER, dm_message_id INTEGER,
            book_id INTEGER, created REAL NOT NULL, updated REAL NOT NULL, reminded REAL);
        CREATE TABLE IF NOT EXISTS kindles (user_id INTEGER PRIMARY KEY, email TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS sends (book_id INTEGER, user_id INTEGER, at REAL, ok INTEGER, detail TEXT);
        CREATE TABLE IF NOT EXISTS cards (request_id INTEGER, approver_id INTEGER, channel_id INTEGER, message_id INTEGER,
            PRIMARY KEY (request_id, approver_id));
        """)

def kv_get(k, default=None):
    with state() as db:
        row = db.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
    return row["v"] if row else default

def kv_set(k, v):
    with state() as db:
        db.execute("INSERT INTO kv VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))

def get_request(rid):
    with state() as db:
        return db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()

def get_request_for(user_id, book_id):
    """The user's fulfilled request for this book, if any (lets a requester press Send on their own DM)."""
    with state() as db:
        return db.execute("SELECT * FROM requests WHERE user_id=? AND book_id=? AND status=?",
                          (user_id, book_id, FULFILLED)).fetchone()

def update_request(rid, **fields):
    fields["updated"] = time.time()
    cols = ", ".join(f"{k}=?" for k in fields)
    with state() as db:
        db.execute(f"UPDATE requests SET {cols} WHERE id=?", (*fields.values(), rid))

def kindle_for(user_id):
    with state() as db:
        row = db.execute("SELECT email FROM kindles WHERE user_id=?", (user_id,)).fetchone()
    return row["email"] if row else (DEFAULT_KINDLE or None)


# ----------------------------- Calibre library (read-only) ------------------
def library():
    # mode=ro: never write to CWA's DB. The library dir is mounted rw so sqlite can use the WAL/shm files.
    db = sqlite3.connect(f"file:{LIBRARY / 'metadata.db'}?mode=ro", uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    return db

BOOK_SQL = """
SELECT b.id, b.title, b.path, b.has_cover,
       (SELECT group_concat(a.name, ' & ') FROM books_authors_link l JOIN authors a ON a.id = l.author
         WHERE l.book = b.id) AS author
FROM books b"""

def library_books(where="", args=()):
    with library() as db:
        return db.execute(f"{BOOK_SQL} {where}", args).fetchall()

def library_book(book_id):
    rows = library_books("WHERE b.id=?", (book_id,))
    return rows[0] if rows else None

def book_file(book):
    """Best file to email for a library book: (path, format) or (None, reason)."""
    with library() as db:
        fmts = {r["format"]: r["name"] for r in db.execute("SELECT format, name FROM data WHERE book=?", (book["id"],))}
    for fmt in SEND_FORMATS:
        if fmt in fmts:
            path = LIBRARY / book["path"] / f"{fmts[fmt]}.{fmt.lower()}"
            if path.exists():
                return path, fmt
    return None, f"no {' or '.join(SEND_FORMATS)} copy (has: {', '.join(fmts) or 'nothing'})"


# ----------------------------- matching --------------------------------------
def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.split(r"[:(\[]", s)[0]                       # drop subtitles / "(Series #3)"
    s = re.sub(r"^(the|a|an)\s+", "", s.strip())
    return re.sub(r"[^a-z0-9]+", " ", s).strip()

def surnames(author):
    # Calibre joins authors with " & "; Open Library gives one name
    parts = re.split(r"\s*&\s*|\s+and\s+", author or "")
    # "Weir, Andy" (sort form some files carry) -> surname comes first
    return {norm(p.split(",")[0]).split()[0] if "," in p else norm(p).split()[-1] for p in parts if norm(p)}

def matches(req, book):
    if difflib.SequenceMatcher(None, norm(req["title"]), norm(book["title"])).ratio() < MATCH_RATIO:
        return False
    a, b = surnames(req["author"]), surnames(book["author"])
    return not a or not b or bool(a & b)      # only compare authors when both sides have one


# ----------------------------- Open Library ----------------------------------
OL_FIELDS = "key,title,author_name,first_publish_year,cover_i"
http: aiohttp.ClientSession | None = None
_ol_cache: dict[str, list] = {}

async def ol_search(q, limit=10):
    q = q.strip()
    if len(q) < 3:
        return []
    if q in _ol_cache:
        return _ol_cache[q]
    try:
        async with http.get("https://openlibrary.org/search.json",
                            params={"q": q, "fields": OL_FIELDS, "limit": limit},
                            timeout=aiohttp.ClientTimeout(total=2.5)) as r:
            docs = (await r.json()).get("docs", [])
    except (aiohttp.ClientError, asyncio.TimeoutError):
        return []
    _ol_cache[q] = docs
    if len(_ol_cache) > 500:
        _ol_cache.pop(next(iter(_ol_cache)))
    return docs

async def ol_work(key):
    """Look up one work by key (OL123W) - normally still cached from the autocomplete that offered it."""
    for docs in _ol_cache.values():
        for d in docs:
            if d.get("key") == f"/works/{key}":
                return d
    docs = await ol_search(f"key:/works/{key}", limit=1)
    return docs[0] if docs else None

def ol_label(d):
    s = d.get("title", "?")
    if d.get("author_name"):
        s += f" - {d['author_name'][0]}"
    if d.get("first_publish_year"):
        s += f" ({d['first_publish_year']})"
    return s[:100]


# ----------------------------- Discord ----------------------------------------
intents = discord.Intents.default()
client = discord.Client(intents=intents, allowed_mentions=discord.AllowedMentions(users=True, roles=False, everyone=False))
tree = app_commands.CommandTree(client)
guild_obj = discord.Object(id=GUILD_ID)
# Discord can only hide whole commands, so the family command and the admin ones are separate
admin = app_commands.Group(name="books", description="Book bot admin", guild_only=True,
                           default_permissions=discord.Permissions(administrator=True))


def allowed(inter: discord.Interaction):
    if inter.user.id in APPROVER_IDS:
        return True
    roles = {r.id for r in getattr(inter.user, "roles", [])}
    return bool(roles & ALLOWED_ROLE_IDS)

async def deny(inter):
    await inter.response.send_message("Sorry, book requests are for family members only.", ephemeral=True)

def cover_url(req):
    return f"https://covers.openlibrary.org/b/id/{req['cover_id']}-M.jpg" if req["cover_id"] else None

def last_send(req):
    """Most recent send of this request's book to its requester: sqlite Row (ok, at) or None."""
    if not req["book_id"]:
        return None
    with state() as db:
        return db.execute("SELECT ok, at FROM sends WHERE book_id=? AND user_id=? ORDER BY at DESC LIMIT 1",
                          (req["book_id"], req["user_id"])).fetchone()

def request_embed(req, for_requester=False):
    icon, text = STATUS_TEXT[req["status"]]
    sent = last_send(req) if req["status"] == FULFILLED else None
    if for_requester and sent and sent["ok"]:
        icon, text = "📨", "On your Kindle"
    title = req["title"] + (f" ({req['year']})" if req["year"] else "")
    e = discord.Embed(title=title[:256], color=STATUS_COLOR[req["status"]],
                      url=f"https://openlibrary.org/works/{req['work_key']}" if req["work_key"] else None)
    if req["author"]:
        e.add_field(name="Author", value=req["author"][:1024], inline=True)
    if not for_requester:
        e.add_field(name="Requested by", value=f"<@{req['user_id']}>", inline=True)
    e.add_field(name="Status", value=f"{icon} {text}", inline=True)
    if req["notes"]:
        e.add_field(name="Notes", value=req["notes"][:1024], inline=False)
    if req["reason"]:
        e.add_field(name="Reason", value=req["reason"][:1024], inline=False)
    if not for_requester and req["status"] == FULFILLED:
        if sent:
            e.add_field(name="Kindle", value=f"📨 Sent <t:{int(sent['at'])}:f>" if sent["ok"] else "⚠️ Not sent - see #warnings", inline=False)
        b = library_book(req["book_id"]) if req["book_id"] else None
        if b and norm(b["title"]) != norm(req["title"]):    # only worth a look when the match wasn't exact
            e.add_field(name="Matched library copy", value=f"{b['title']} - {b['author'] or '?'}"[:1024], inline=False)
    if url := cover_url(req):
        e.set_thumbnail(url=url)
    if not for_requester:
        e.set_footer(text=f"Request #{req['id']}")
    return e

def card_view(req):
    """Buttons on the approver's card. Custom ids carry the request id, so they survive restarts."""
    v = discord.ui.View(timeout=None)
    if req["status"] == OPEN:
        v.add_item(discord.ui.Button(label="Approve", style=discord.ButtonStyle.success, custom_id=f"book:approve:{req['id']}"))
    if req["status"] in (OPEN, APPROVED):
        v.add_item(discord.ui.Button(label="Decline", style=discord.ButtonStyle.danger, custom_id=f"book:decline:{req['id']}"))
    if req["status"] == FULFILLED and req["book_id"]:
        v.add_item(discord.ui.Button(label="Resend to Kindle", emoji="📨", style=discord.ButtonStyle.secondary,
                                     custom_id=f"book:resend:{req['id']}"))
    return v

def dm_view(req):
    v = discord.ui.View(timeout=None)
    if req["status"] == FULFILLED and req["book_id"] and not AUTO_SEND:
        v.add_item(discord.ui.Button(label="Send to Kindle", emoji="📨", style=discord.ButtonStyle.primary,
                                     custom_id=f"book:send:{req['book_id']}"))
    if req["status"] in (OPEN, APPROVED):
        v.add_item(discord.ui.Button(label="Cancel request", style=discord.ButtonStyle.secondary,
                                     custom_id=f"book:cancel:{req['id']}"))
    return v

async def warn(text):
    ch = client.get_channel(WARN_CHANNEL_ID)
    if ch:
        await ch.send(f"📚 **book-requests:** {text}")
    log.warning(text)

async def refresh(rid, ping_requester: str | None = None):
    """Re-render the approver cards and the requester's DM card; optionally send a new (pinging) DM."""
    req = get_request(rid)
    await ensure_card(req)
    if req["dm_channel_id"] and req["dm_message_id"]:
        try:
            dm = await client.fetch_channel(req["dm_channel_id"])
            # "Got it..." only makes sense while it's waiting; after that the status field says it all
            content = "Got it - I'll message you when it's on your Kindle." if req["status"] == OPEN else None
            await dm.get_partial_message(req["dm_message_id"]).edit(content=content, embed=request_embed(req, True), view=dm_view(req))
        except discord.HTTPException as ex:
            log.warning("dm edit #%s failed: %s", rid, ex)
    if ping_requester:
        await notify(req["user_id"], ping_requester, view=dm_view(req))

async def ensure_card(req):
    """Edit each approver's DM card; post a fresh one where it's missing (new request, or deleted)."""
    for approver in APPROVER_IDS:
        with state() as db:
            card = db.execute("SELECT * FROM cards WHERE request_id=? AND approver_id=?", (req["id"], approver)).fetchone()
        if card:
            try:
                ch = await client.fetch_channel(card["channel_id"])
                await ch.get_partial_message(card["message_id"]).edit(embed=request_embed(req), view=card_view(req))
                continue
            except discord.NotFound:
                pass
            except discord.HTTPException as ex:
                log.warning("card edit #%s for %s failed: %s", req["id"], approver, ex)
                continue
        if req["status"] not in (OPEN, APPROVED):
            continue                        # don't resurrect cards for finished requests
        msg = await notify(approver, "📚 New book request", embed=request_embed(req), view=card_view(req))
        with state() as db:
            db.execute("INSERT OR REPLACE INTO cards VALUES (?,?,?,?)", (req["id"], approver, msg.channel.id, msg.id))

async def notify(user_id, text, embed=None, view=None):
    """DM a user; if their DMs are closed, post in #books with a mention instead. Returns the message."""
    try:
        user = await client.fetch_user(user_id)
        return await user.send(text, embed=embed, view=view or discord.utils.MISSING)
    except discord.Forbidden:
        ch = client.get_channel(BOOKS_CHANNEL_ID)
        return await ch.send(f"<@{user_id}> {text}", embed=embed, view=view or discord.utils.MISSING)


# ----------------------------- sending to Kindle -----------------------------
def _smtp_send(to, path: Path):
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = SMTP_FROM, to, path.stem
    msg.set_content("Sent by book-requests.")
    subtype = "epub+zip" if path.suffix.lower() == ".epub" else "pdf"
    msg.add_attachment(path.read_bytes(), maintype="application", subtype=subtype, filename=path.name)
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=60) as s:
        s.starttls()
        s.login(SMTP_USER, SMTP_PASS)
        s.send_message(msg)

async def send_to_kindle(user_id, book_id, to=None):
    """Returns (ok, message for the user). Failures go to #warnings - fixing them is the admin's job."""
    to = to or kindle_for(user_id)
    b = library_book(book_id)
    if not b:
        return False, "That book isn't in the library any more."
    if not to:
        await warn(f"no Kindle address for <@{user_id}> - can't send **{b['title']}** (set DEFAULT_KINDLE or `/books kindle`)")
        return False, f"**{b['title']}** is in the library - it'll be on your Kindle soon."
    path, fmt = book_file(b)
    if not path:
        await warn(f"can't send **{b['title']}** (book {book_id}): {fmt}")
        return False, f"**{b['title']}** is in the library - it'll be on your Kindle soon."
    if path.stat().st_size > KINDLE_MAX_BYTES:
        await warn(f"**{b['title']}** is {path.stat().st_size // 2**20} MB, over the 50 MB Send to Kindle email limit")
        return False, f"**{b['title']}** is in the library - it'll be on your Kindle soon."
    try:
        await asyncio.to_thread(_smtp_send, to, path)
    except Exception as ex:
        with state() as db:
            db.execute("INSERT INTO sends VALUES (?,?,?,0,?)", (book_id, user_id, time.time(), str(ex)[:500]))
        await warn(f"SMTP send of **{b['title']}** to `{to}` failed: `{ex}`")
        return False, f"**{b['title']}** is in the library - it'll be on your Kindle soon."
    with state() as db:
        db.execute("INSERT INTO sends VALUES (?,?,?,1,?)", (book_id, user_id, time.time(), fmt))
    log.info("sent book %s (%s) to %s for user %s", book_id, fmt, to, user_id)
    return True, (f"📨 **{b['title']}** is on its way to your Kindle - it usually shows up within a few minutes "
                  f"(the Kindle needs to be on Wi-Fi).")


# ----------------------------- commands ---------------------------------------
@app_commands.command(name="book", description="Ask for a book for the Kindle")
@app_commands.guild_only()
@app_commands.describe(title="Start typing a title or author", notes="Anything that helps (series number, edition...)")
async def cmd_request(inter: discord.Interaction, title: str, notes: str | None = None):
    if not allowed(inter):
        return await deny(inter)
    await inter.response.defer(ephemeral=True)
    # Autocomplete values are work keys (OL123W); typed text that wasn't picked is searched instead
    doc = await ol_work(title) if re.fullmatch(r"OL\d+W", title) else None
    if not doc:
        hits = await ol_search(title, limit=1)
        doc = hits[0] if hits else {"title": title}
    work_key = (doc.get("key") or "").removeprefix("/works/") or None
    req = {"title": doc.get("title") or title, "author": (doc.get("author_name") or [None])[0]}

    with state() as db:
        dup = db.execute("SELECT id, status FROM requests WHERE status IN (?,?) AND (work_key=? OR lower(title)=lower(?))",
                         (OPEN, APPROVED, work_key, req["title"])).fetchone()
    if dup:
        return await inter.followup.send(f"**{req['title']}** is already requested (#{dup['id']}, {STATUS_TEXT[dup['status']][1].lower()}).", ephemeral=True)

    have = next((b for b in library_books() if matches(req, b)), None)
    if have:
        if not AUTO_SEND:
            return await inter.followup.send(f"Good news - **{have['title']}** by {have['author'] or '?'} is already in the library.", ephemeral=True)
        ok, msg = await send_to_kindle(inter.user.id, have["id"])
        return await inter.followup.send(f"Good news - it's already in the library! {msg}", ephemeral=True)

    now = time.time()
    with state() as db:
        rid = db.execute("""INSERT INTO requests (user_id, work_key, title, author, year, cover_id, notes, status, created, updated)
                            VALUES (?,?,?,?,?,?,?,?,?,?)""",
                         (inter.user.id, work_key, req["title"], req["author"], doc.get("first_publish_year"),
                          doc.get("cover_i"), notes, OPEN, now, now)).lastrowid
    r = get_request(rid)
    await ensure_card(r)
    if inter.user.id not in APPROVER_IDS:   # an approver's own request already has the approval card
        dm = await notify(inter.user.id, "Got it - I'll message you when it's on your Kindle.", embed=request_embed(r, True), view=dm_view(r))
        update_request(rid, dm_channel_id=dm.channel.id, dm_message_id=dm.id)
    log.info("request #%s by %s: %s", rid, inter.user, req["title"])
    await inter.followup.send(f"Requested **{req['title']}**. I'll message you when it's on your Kindle.", ephemeral=True)

@cmd_request.autocomplete("title")
async def ac_request(inter: discord.Interaction, current: str):
    docs = await ol_search(current)
    return [app_commands.Choice(name=ol_label(d), value=d["key"].removeprefix("/works/")) for d in docs if d.get("key")][:25]


async def deny_admin(inter):
    # default_permissions only hides /books - a server admin could re-grant it, so check here too
    await inter.response.send_message("That's an admin command.", ephemeral=True)

@admin.command(name="list", description="Recent book requests from everyone")
async def cmd_list(inter: discord.Interaction):
    if inter.user.id not in APPROVER_IDS:
        return await deny_admin(inter)
    with state() as db:
        rows = db.execute("SELECT * FROM requests ORDER BY id DESC LIMIT 20").fetchall()
    if not rows:
        return await inter.response.send_message("No requests yet.", ephemeral=True)
    lines = [f"{STATUS_TEXT[r['status']][0]} #{r['id']} **{r['title']}** - <@{r['user_id']}>, "
             f"{STATUS_TEXT[r['status']][1].lower()}" for r in rows]
    await inter.response.send_message("\n".join(lines), ephemeral=True, allowed_mentions=discord.AllowedMentions.none())


@admin.command(name="send", description="Email a library book to a Kindle")
@app_commands.describe(title="Start typing a title or author", user="Whose Kindle (default: yours)")
async def cmd_send(inter: discord.Interaction, title: str, user: discord.Member | None = None):
    if inter.user.id not in APPROVER_IDS:
        return await deny_admin(inter)
    if not title.isdigit():
        return await inter.response.send_message("Pick a book from the list as you type.", ephemeral=True)
    await inter.response.defer(ephemeral=True)
    who = (user or inter.user).id
    ok, msg = await send_to_kindle(who, int(title))
    await inter.followup.send(msg if ok else "Send failed - see #warnings.", ephemeral=True)
    if req := get_request_for(who, int(title)):     # keep that request's cards' Kindle line current
        await refresh(req["id"])

def library_choices(current):
    q = f"%{current.strip()}%"
    rows = library_books("""WHERE b.title LIKE ? OR b.id IN (SELECT l.book FROM books_authors_link l JOIN authors a
                            ON a.id = l.author WHERE a.name LIKE ?) ORDER BY b.timestamp DESC LIMIT 25""", (q, q))
    return [app_commands.Choice(name=f"{r['title']} - {r['author'] or '?'}"[:100], value=str(r["id"])) for r in rows]

@cmd_send.autocomplete("title")
async def ac_send(inter, current: str):
    return library_choices(current)


@admin.command(name="kindle", description="Set or show the Kindle address a person's books go to")
@app_commands.describe(email="Send-to-Kindle address (Amazon > Manage Content & Devices > Devices)",
                       user="Whose (default: yours)")
async def cmd_kindle(inter: discord.Interaction, email: str | None = None, user: discord.Member | None = None):
    if inter.user.id not in APPROVER_IDS:
        return await deny_admin(inter)
    who = user or inter.user
    if not email:
        cur = kindle_for(who.id)
        return await inter.response.send_message(f"{who.display_name}'s books go to `{cur}`." if cur else "No Kindle address set.", ephemeral=True)
    email = email.strip().lower()
    if not re.fullmatch(r"[^@\s]+@(free\.)?kindle\.com", email):
        return await inter.response.send_message("That should be an `@kindle.com` address.", ephemeral=True)
    with state() as db:
        db.execute("INSERT INTO kindles VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET email=excluded.email", (who.id, email))
    await inter.response.send_message(
        f"Saved - {who.display_name}'s books will go to `{email}`.\nMake sure `{SMTP_FROM}` is on the approved list in Amazon "
        "(Manage Content & Devices > Preferences > Personal Document Settings).", ephemeral=True)


@admin.command(name="link", description="Mark a request fulfilled with a library book")
async def cmd_link(inter: discord.Interaction, request: int, title: str):
    if inter.user.id not in APPROVER_IDS:
        return await deny_admin(inter)
    req = get_request(request)
    if not req or not title.isdigit() or not library_book(int(title)):
        return await inter.response.send_message("Pick a request and a library book from the lists.", ephemeral=True)
    await inter.response.defer(ephemeral=True)
    await fulfil(req, library_book(int(title)))
    await inter.followup.send(f"Linked #{request} to book {title}.", ephemeral=True)

@cmd_link.autocomplete("request")
async def ac_link_request(inter, current: str):
    with state() as db:
        rows = db.execute("SELECT id, title FROM requests WHERE status IN (?,?) ORDER BY id DESC LIMIT 25", (OPEN, APPROVED)).fetchall()
    return [app_commands.Choice(name=f"#{r['id']} {r['title']}"[:100], value=r["id"]) for r in rows
            if current.lower() in f"#{r['id']} {r['title']}".lower()]

@cmd_link.autocomplete("title")
async def ac_link_title(inter, current: str):
    return library_choices(current)

tree.add_command(cmd_request, guild=guild_obj)
tree.add_command(admin, guild=guild_obj)


# ----------------------------- buttons ----------------------------------------
class DeclineModal(discord.ui.Modal, title="Decline request"):
    reason = discord.ui.TextInput(label="Reason (shown to the requester)", required=False, max_length=300)

    def __init__(self, rid):
        super().__init__()
        self.rid = rid

    async def on_submit(self, inter: discord.Interaction):
        update_request(self.rid, status=DECLINED, reason=str(self.reason) or None)
        await inter.response.send_message("Declined.", ephemeral=True)
        await refresh(self.rid, ping_requester=f"Sorry - **{get_request(self.rid)['title']}** was declined.")

@client.event
async def on_interaction(inter: discord.Interaction):
    if inter.type != discord.InteractionType.component:
        return
    cid = (inter.data or {}).get("custom_id", "")
    if not cid.startswith("book:"):
        return
    _, action, arg = cid.split(":", 2)
    arg = int(arg)

    if action == "send":                    # only on approver-side messages (AUTO_SEND=false DMs, old #books posts)
        if inter.user.id not in APPROVER_IDS and not get_request_for(inter.user.id, arg):
            return await inter.response.send_message("Only an admin can send that one.", ephemeral=True)
        await inter.response.defer(ephemeral=True, thinking=True)
        ok, msg = await send_to_kindle(inter.user.id, arg)
        return await inter.followup.send(msg, ephemeral=True)

    req = get_request(arg)
    if not req:
        return await inter.response.send_message("That request no longer exists.", ephemeral=True)

    if action == "cancel":
        if inter.user.id != req["user_id"] or req["status"] not in (OPEN, APPROVED):
            return await inter.response.send_message("Nothing to cancel.", ephemeral=True)
        update_request(arg, status=CANCELLED)
        await inter.response.send_message("Request cancelled.", ephemeral=True)
        return await refresh(arg)

    if inter.user.id not in APPROVER_IDS:
        return await inter.response.send_message("Only an approver can do that.", ephemeral=True)
    if action == "resend" and req["status"] == FULFILLED and req["book_id"]:
        await inter.response.defer(ephemeral=True, thinking=True)
        ok, msg = await send_to_kindle(req["user_id"], req["book_id"])
        await inter.followup.send(f"Resent to `{kindle_for(req['user_id'])}`." if ok else "Send failed - see #warnings.", ephemeral=True)
        return await refresh(arg)
    if action == "approve" and req["status"] == OPEN:
        update_request(arg, status=APPROVED)
        await inter.response.send_message(f"Approved #{arg}. Drop the file in the ingest folder and I'll pick it up.", ephemeral=True)
        await refresh(arg)      # the requester's DM card updates silently - one ping for "ready" is enough
    elif action == "decline" and req["status"] in (OPEN, APPROVED):
        await inter.response.send_modal(DeclineModal(arg))
    else:
        await inter.response.send_message(f"Request is already {req['status']}.", ephemeral=True)


# ----------------------------- library watcher ---------------------------------
async def fulfil(req, b):
    update_request(req["id"], status=FULFILLED, book_id=b["id"])
    log.info("request #%s fulfilled by book %s", req["id"], b["id"])
    if not AUTO_SEND:
        return await refresh(req["id"], ping_requester=f"📚 **{b['title']}** is ready! Press the button to send it to your Kindle.")
    ok, msg = await send_to_kindle(req["user_id"], b["id"])
    await refresh(req["id"], ping_requester=msg if ok else None)   # on failure #warnings has it; she hears once it's sent

async def announce(b):
    ch = client.get_channel(BOOKS_CHANNEL_ID)
    if not ch:
        return
    e = discord.Embed(title=b["title"][:256], description=b["author"] or None, color=0x8E44AD, url=CWA_URL or None)
    e.set_author(name="New in the library")
    files = []
    cover = LIBRARY / b["path"] / "cover.jpg"
    if b["has_cover"] and cover.exists():
        files.append(discord.File(cover, filename="cover.jpg"))
        e.set_thumbnail(url="attachment://cover.jpg")
    await ch.send(embed=e, files=files)     # no buttons: everyone in the channel would see them

_settling: set[int] = set()     # new book ids seen last poll - CWA may still be fixing metadata, so wait one round

@tasks.loop(seconds=POLL_SECONDS)
async def poll():
    ok = True
    try:
        last = int(kv_get("last_book_id", "0"))
        rows = library_books("WHERE b.id > ? ORDER BY b.id", (last,))
        ready = [b for b in rows if b["id"] in _settling]
        _settling.clear()
        _settling.update(b["id"] for b in rows if b["id"] not in {r["id"] for r in ready})
        for b in sorted(ready, key=lambda r: r["id"]):
            b = library_book(b["id"])            # re-read: title/author may have changed since
            if not b:
                continue
            await announce(b)
            with state() as db:
                open_reqs = db.execute("SELECT * FROM requests WHERE status IN (?,?) ORDER BY id", (OPEN, APPROVED)).fetchall()
            for req in open_reqs:
                if matches(req, b):
                    await fulfil(req, b)
            kv_set("last_book_id", b["id"])

        # Files CWA hasn't consumed are usually ones it couldn't import
        stuck = [p.name for p in INGEST.rglob("*") if p.is_file() and time.time() - p.stat().st_mtime > INGEST_STUCK_MINUTES * 60]
        sig = "|".join(sorted(stuck))
        if stuck and sig != kv_get("stuck_sig"):
            await warn(f"{len(stuck)} file(s) sitting in the ingest folder for {INGEST_STUCK_MINUTES}+ min "
                       f"(CWA probably couldn't import them): " + ", ".join(f"`{n}`" for n in stuck[:10]))
        kv_set("stuck_sig", sig)

        cutoff = time.time() - STALE_DAYS * 86400
        with state() as db:
            stale = db.execute("SELECT * FROM requests WHERE status=? AND updated < ? AND (reminded IS NULL OR reminded < ?)",
                               (APPROVED, cutoff, cutoff)).fetchall()
        for req in stale:
            await warn(f"request #{req['id']} **{req['title']}** for <@{req['user_id']}> was approved {STALE_DAYS}+ days ago "
                       "and nothing matching has reached the library (use `/book link` if it's there under another title)")
            with state() as db:
                db.execute("UPDATE requests SET reminded=? WHERE id=?", (time.time(), req["id"]))
    except Exception:
        ok = False
        log.exception("poll failed")
    if HC_PING_URL:
        try:
            async with http.get(HC_PING_URL + ("" if ok else "/fail"), timeout=aiohttp.ClientTimeout(total=10)):
                pass
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass

@client.event
async def on_ready():
    global http
    if http is None:
        http = aiohttp.ClientSession(headers={"User-Agent": "book-requests (homelab Discord bot)"})
    if kv_get("last_book_id") is None:          # first run: don't announce the whole existing library
        rows = library_books("ORDER BY b.id DESC LIMIT 1")
        kv_set("last_book_id", rows[0]["id"] if rows else 0)
    if not poll.is_running():               # on_ready fires again after reconnects
        await tree.sync(guild=guild_obj)
        with state() as db:
            live = db.execute("SELECT * FROM requests WHERE status IN (?,?)", (OPEN, APPROVED)).fetchall()
        for req in live:
            await ensure_card(req)
        poll.start()
    log.info("ready as %s", client.user)


if __name__ == "__main__":
    init_state()
    client.run(TOKEN, log_handler=None)
