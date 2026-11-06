// Thin client for the Bukka API. Same origin: Nginx (or the Vite dev proxy)
// routes /api to the API server.

async function request(path, options = {}) {
  const resp = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!resp.ok) {
    let detail = `${resp.status} ${resp.statusText}`;
    try {
      const body = await resp.json();
      if (body.detail) detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      // Not JSON: e.g. an Nginx 502 page when the API is down.
    }
    const err = new Error(detail);
    err.status = resp.status;
    throw err;
  }
  return resp.json();
}

export const api = {
  restaurants: () => request("/api/restaurants"),
  menu: (slug) => request(`/api/restaurants/${slug}/menu`),
  placeOrder: (body) => request("/api/orders", { method: "POST", body: JSON.stringify(body) }),
  order: (id) => request(`/api/orders/${id}`),
  kitchenOrders: () => request("/api/kitchen/orders"),
  setStatus: (id, status) =>
    request(`/api/orders/${id}/status`, { method: "PATCH", body: JSON.stringify({ status }) }),
};

export const naira = (kobo) =>
  "₦" + (kobo / 100).toLocaleString("en-NG", { minimumFractionDigits: 0, maximumFractionDigits: 2 });

export const STATUSES = ["placed", "preparing", "out_for_delivery", "delivered"];
export const STATUS_LABEL = {
  placed: "Order placed",
  preparing: "Preparing",
  out_for_delivery: "Out for delivery",
  delivered: "Delivered",
};
