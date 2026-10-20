FROM ghcr.io/gohugoio/hugo:v0.168.0 AS build
USER root
WORKDIR /src
COPY . .
RUN hugo --minify --destination /out

FROM nginxinc/nginx-unprivileged:stable-alpine
COPY --from=build /out /usr/share/nginx/html
