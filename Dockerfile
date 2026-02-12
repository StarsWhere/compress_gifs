FROM python:3.12-alpine

WORKDIR /usr/src/app

# Copy static assets
COPY . .

# Expose HTTP port used by python -m http.server
EXPOSE 8086

CMD ["python", "-m", "http.server", "8086"]
