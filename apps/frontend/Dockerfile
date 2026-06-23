# No build step: it's static HTML/JS. Just copy it into the nginx image.
FROM nginx:1.27-alpine

# nginx serves everything under this dir on port 80 by default.
COPY index.html /usr/share/nginx/html/index.html
