Registers probes (workspace facts, tool finders); facts in, no work units.

The workspace parser lives here, not in units/: it turns pnpm-workspace.yaml
and package.json into a package graph and registers the install probe — facts,
no work units. Its consumer is the registrar, but it registers nothing itself.
