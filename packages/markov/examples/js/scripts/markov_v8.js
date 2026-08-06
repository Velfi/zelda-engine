(() => {
  const lib = globalThis.rt.markov;
  // DUMBAI: smoke-check one generated symbol for rt/markov through V8.
  const symbol = "add_neighbor_constraint";
  const ok = !!lib && typeof lib[symbol] === "function";
  return `[v8] rt/markov ${symbol}: ${ok ? "ok" : "missing"}`;
})()
