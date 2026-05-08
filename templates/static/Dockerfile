FROM nginx:alpine

# Copy static assets to Nginx default public directory
COPY ./src /usr/share/nginx/html

# Expose port 80
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
