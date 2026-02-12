FROM nginx:1.27-alpine

# Copy custom nginx config (adds wasm mime + simple SPA fallback)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy static assets
COPY . /usr/share/nginx/html

# Expose HTTP port
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
