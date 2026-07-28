# Unicode dependencies

The text bridge vendors two small C libraries so Unicode behavior is identical
on every supported platform:

- **SheenBidi 3.0.0**, commit `cfe430e7375a7845b679adae9d51dac6deaa8858`,
  Apache-2.0. Source: <https://github.com/Tehreer/SheenBidi>.
- **libgrapheme 3.0.0**, Unicode 17.0.0 data, commit
  `bf20d2f7bce13c7d006a9ca442221399753bce9d`, ISC. Source:
  <https://git.suckless.org/libgrapheme>.

Only runtime sources, generated Unicode lookup tables, public headers, and
license files are retained. Regenerate libgrapheme lookup headers from its
pinned source tree before updating the vendored copy.
