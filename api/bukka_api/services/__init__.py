"""Bukka split into services. Each one is the same package with a subset of
the routes, its own /healthz and /readyz, and the shared database."""
