FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py .
# nobody:users, same as the rest of the Unraid containers (reads the CWA library, writes /data)
USER 99:100
CMD ["python", "-u", "bot.py"]
