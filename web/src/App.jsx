import { useEffect, useState } from "react";
import { api, naira, STATUSES, STATUS_LABEL } from "./api.js";

// Tiny hash router: #/, #/r/<slug>, #/order/<id>, #/kitchen
function useRoute() {
  const [hash, setHash] = useState(window.location.hash || "#/");
  useEffect(() => {
    const onChange = () => setHash(window.location.hash || "#/");
    window.addEventListener("hashchange", onChange);
    return () => window.removeEventListener("hashchange", onChange);
  }, []);
  return hash.replace(/^#/, "").split("/").filter(Boolean);
}

export default function App() {
  const route = useRoute();
  let page;
  if (route[0] === "r" && route[1]) page = <Menu slug={route[1]} />;
  else if (route[0] === "order" && route[1]) page = <OrderTracker id={route[1]} />;
  else if (route[0] === "kitchen") page = <Kitchen />;
  else page = <Restaurants />;

  return (
    <>
      <header className="topbar">
        <a href="#/" className="brand">🍲 Bukka</a>
        <nav>
          <a href="#/">Restaurants</a>
          <a href="#/kitchen">Kitchen</a>
        </nav>
      </header>
      <main className="container">{page}</main>
      <footer className="footer">Bukka · Lagos · Made by the platform team</footer>
    </>
  );
}

function Problem({ error, retry }) {
  return (
    <div className="problem">
      <h2>We can't load this right now</h2>
      <p>The kitchen might be busy. Please try again in a moment.</p>
      <p className="muted small">Details: {error.message}</p>
      {retry && <button onClick={retry}>Try again</button>}
    </div>
  );
}

function useLoad(fn, deps) {
  const [state, setState] = useState({ data: null, error: null, loading: true });
  const load = () => {
    setState((s) => ({ ...s, loading: true, error: null }));
    fn().then(
      (data) => setState({ data, error: null, loading: false }),
      (error) => setState({ data: null, error, loading: false })
    );
  };
  useEffect(load, deps);
  return { ...state, reload: load };
}

function Restaurants() {
  const { data, error, loading, reload } = useLoad(api.restaurants, []);
  if (loading) return <p className="muted">Loading restaurants…</p>;
  if (error) return <Problem error={error} retry={reload} />;
  return (
    <>
      <section className="hero">
        <h1>Hungry? Your favourite bukka delivers.</h1>
        <p>Jollof, suya, amala and more, from kitchens across Lagos.</p>
      </section>
      <div className="grid">
        {data.map((r) => (
          <a key={r.id} href={`#/r/${r.slug}`} className="card restaurant">
            <div className="emoji">{r.emoji}</div>
            <div>
              <h3>{r.name}</h3>
              <p className="muted">{r.cuisine} · {r.area}</p>
              <p className="small">🛵 {r.delivery_minutes} min</p>
            </div>
          </a>
        ))}
      </div>
    </>
  );
}

function Menu({ slug }) {
  const { data, error, loading, reload } = useLoad(() => api.menu(slug), [slug]);
  const [cart, setCart] = useState({});
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [placing, setPlacing] = useState(false);
  const [placeError, setPlaceError] = useState("");

  if (loading) return <p className="muted">Loading menu…</p>;
  if (error) return <Problem error={error} retry={reload} />;

  const add = (id, n) =>
    setCart((c) => {
      const q = Math.max(0, (c[id] || 0) + n);
      const next = { ...c, [id]: q };
      if (q === 0) delete next[id];
      return next;
    });
  const lines = data.dishes.filter((d) => cart[d.id]);
  const total = lines.reduce((sum, d) => sum + d.price_kobo * cart[d.id], 0);

  const placeOrder = async (e) => {
    e.preventDefault();
    setPlacing(true);
    setPlaceError("");
    try {
      const order = await api.placeOrder({
        restaurant_slug: slug,
        customer_name: name,
        delivery_address: address,
        items: lines.map((d) => ({ dish_id: d.id, quantity: cart[d.id] })),
      });
      window.location.hash = `#/order/${order.id}`;
    } catch (err) {
      setPlaceError(err.message);
      setPlacing(false);
    }
  };

  return (
    <div className="menu-layout">
      <div>
        <a href="#/" className="back">← All restaurants</a>
        <h1>{data.emoji} {data.name}</h1>
        <p className="muted">{data.cuisine} · {data.area} · 🛵 {data.delivery_minutes} min</p>
        <ul className="dishes">
          {data.dishes.map((d) => (
            <li key={d.id} className="card dish">
              <div className="emoji">{d.emoji}</div>
              <div className="grow">
                <h3>{d.name}</h3>
                <p className="muted small">{d.description}</p>
                <strong>{naira(d.price_kobo)}</strong>
              </div>
              <div className="qty">
                {cart[d.id] ? (
                  <>
                    <button onClick={() => add(d.id, -1)} aria-label={`Remove one ${d.name}`}>−</button>
                    <span>{cart[d.id]}</span>
                  </>
                ) : null}
                <button onClick={() => add(d.id, 1)} aria-label={`Add ${d.name}`}>+</button>
              </div>
            </li>
          ))}
        </ul>
      </div>
      <aside className="card cart">
        <h2>Your order</h2>
        {lines.length === 0 ? (
          <p className="muted">Add something tasty.</p>
        ) : (
          <form onSubmit={placeOrder}>
            {lines.map((d) => (
              <div key={d.id} className="line">
                <span>{cart[d.id]} × {d.name}</span>
                <span>{naira(d.price_kobo * cart[d.id])}</span>
              </div>
            ))}
            <div className="line total"><span>Total</span><span>{naira(total)}</span></div>
            <label>Name<input value={name} onChange={(e) => setName(e.target.value)} required /></label>
            <label>Delivery address<input value={address} onChange={(e) => setAddress(e.target.value)} required /></label>
            {placeError && <p className="error">{placeError}</p>}
            <button type="submit" disabled={placing}>{placing ? "Placing order…" : `Place order · ${naira(total)}`}</button>
          </form>
        )}
      </aside>
    </div>
  );
}

function OrderTracker({ id }) {
  const [order, setOrder] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    let alive = true;
    const tick = () =>
      api.order(id).then(
        (o) => alive && (setOrder(o), setError(null)),
        (e) => alive && setError(e)
      );
    tick();
    const timer = setInterval(tick, 3000);
    return () => { alive = false; clearInterval(timer); };
  }, [id]);

  if (error && !order) return <Problem error={error} />;
  if (!order) return <p className="muted">Loading your order…</p>;
  const step = STATUSES.indexOf(order.status);
  return (
    <div className="card tracker">
      <h1>Order #{order.id}</h1>
      <p className="muted">{order.restaurant_name} → {order.delivery_address}</p>
      <ol className="steps">
        {STATUSES.map((s, i) => (
          <li key={s} className={i <= step ? "done" : ""}>{STATUS_LABEL[s]}</li>
        ))}
      </ol>
      <ul className="plain">
        {order.items.map((it) => (
          <li key={it.dish_id} className="line">
            <span>{it.quantity} × {it.dish_name}</span><span>{naira(it.unit_price_kobo * it.quantity)}</span>
          </li>
        ))}
        <li className="line total"><span>Total</span><span>{naira(order.total_kobo)}</span></li>
      </ul>
      {error && <p className="error small">Live updates paused: {error.message}</p>}
    </div>
  );
}

function Kitchen() {
  const [orders, setOrders] = useState(null);
  const [error, setError] = useState(null);
  const load = () => api.kitchenOrders().then((o) => (setOrders(o), setError(null)), setError);
  useEffect(() => {
    load();
    const timer = setInterval(load, 3000);
    return () => clearInterval(timer);
  }, []);

  const advance = async (o) => {
    const next = STATUSES[STATUSES.indexOf(o.status) + 1];
    try {
      await api.setStatus(o.id, next);
      load();
    } catch (e) {
      setError(e);
    }
  };

  if (error && !orders) return <Problem error={error} retry={load} />;
  if (!orders) return <p className="muted">Loading kitchen…</p>;
  return (
    <>
      <h1>👩🏾‍🍳 Kitchen screen</h1>
      <p className="muted">Orders still in progress, oldest first. Updates every few seconds.</p>
      {orders.length === 0 && <p className="card muted">No open orders. Time for a break.</p>}
      <div className="grid">
        {orders.map((o) => {
          const next = STATUSES[STATUSES.indexOf(o.status) + 1];
          return (
            <div key={o.id} className={`card ticket status-${o.status}`}>
              <div className="line"><strong>#{o.id} · {o.customer_name}</strong><span className="pill">{STATUS_LABEL[o.status]}</span></div>
              <p className="muted small">{o.restaurant_name}</p>
              <ul className="plain small">
                {o.items.map((it) => <li key={it.dish_id}>{it.quantity} × {it.dish_name}</li>)}
              </ul>
              {next && <button onClick={() => advance(o)}>Mark “{STATUS_LABEL[next]}”</button>}
            </div>
          );
        })}
      </div>
    </>
  );
}
