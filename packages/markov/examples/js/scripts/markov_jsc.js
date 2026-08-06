(() => {
  const lib = globalThis.rt.markov;
  // DUMBAI: smoke-check one generated symbol for rt/markov through JavaScriptCore.
  const symbol = "add_neighbor_constraint";
  const ok = !!lib && typeof lib[symbol] === "function";
  return `[jsc] rt/markov ${symbol}: ${ok ? "ok" : "missing"}`;
})()
