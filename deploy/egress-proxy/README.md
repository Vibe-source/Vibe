# egress-proxy

tinyproxy between `sandbox-net` and the internet — the only way a sandbox container reaches
anything outside itself. Containers get `HTTP_PROXY`/`HTTPS_PROXY` pointed at this service;
`network:"none"` sandboxes never reach it at all.

`tinyproxy.conf`'s `Allow` restricts *who* can connect — fill in `sandbox-net`'s real CIDR at
the `SANDBOX_SUBNET_PLACEHOLDER` line. `Filter`/`filter` restrict *where* they can go: a
domain allowlist, `FilterDefaultDeny Yes` + `FilterExtended On` (POSIX regex per line,
matched against the request host).

To extend the allowlist: add a line to `filter` below the marked block. Each line is a
regex, not a literal string — escape dots (`\.`) and anchor with `^`/`$`.

**Removing or emptying `filter`, or flipping `FilterDefaultDeny` to `No`, gives every
sandbox open internet egress.** That is a policy decision, not a quick unblock — every
domain a sandboxed agent can reach is a domain it can exfiltrate through.

Image: `vimagick/tinyproxy` or the official `tinyproxy` image, this directory mounted at
`/etc/tinyproxy/`.
