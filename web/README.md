# Bukka web

React app (built with Vite) for customers and the kitchen:

- `#/`: restaurants
- `#/r/<slug>`: menu and cart
- `#/order/<id>`: live order tracking
- `#/kitchen`: kitchen screen

It talks to the API on the same origin under `/api`.

## Build for production

```bash
npm ci
npm run build      # static files in dist/
```

`dist/` is plain HTML, CSS and JavaScript. In production a web server
(Nginx) serves those files and forwards requests for `/api/` to the API on
port 8080.

## Develop with hot reload

```bash
npm run dev        # http://localhost:5173, proxies /api to 127.0.0.1:8080
```

Start the API first (see `../api/README.md`).
