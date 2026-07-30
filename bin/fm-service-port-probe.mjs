#!/usr/bin/env node
// Network oracle for bin/fm-service-port.sh: the two questions a shell cannot
// answer portably and must not answer by guessing.
//
// `bind` exists because a successful bind is the ONLY proof that a port is
// free. A registry file cannot stop another UNIX account on the same machine
// from taking a port, and a connect probe cannot see a holder that binds a
// different address on the same port. This probe performs the same
// `net.Server.listen()` a Node service will perform, so its answer is the
// answer the real service gets. It never holds a port: each candidate is bound,
// then immediately closed, so the caller still races anyone else who wants it.
// That residual race is real and is handled by the caller retrying, not by
// pretending the probe reserved anything.
//
// `resolve` exists because the hostname written into a link is only useful if
// it resolves to the address the service actually bound. Checking that before
// the URL is emitted is what keeps a link from failing silently on another
// device.
//
// `http` exists because a readiness probe must target the address the service
// actually bound. Probing loopback while a service binds only a tailnet address
// reports a healthy server as failed to start, which has already cost this
// fleet real time. The optional Host header also lets a caller ask a specific
// server "were you started with my configuration", which no shared health body
// can answer.
//
// Usage:
//   fm-service-port-probe.mjs bind <addr> <port>[ <port>...]
//       Prints the first port that binds on <addr>, exit 0.
//       Exit 3 - every candidate is in use (EADDRINUSE).
//       Exit 4 - <addr> cannot be bound at all on this host
//                (EADDRNOTAVAIL, EACCES, EAFNOSUPPORT); the reason is on stderr.
//                This is NOT a collision and callers must not report it as one.
//   fm-service-port-probe.mjs resolve <hostname> <expected-ipv4>
//       Exit 0 - <hostname> resolves over IPv4 to <expected-ipv4>.
//       Exit 1 - it does not resolve, or resolves elsewhere; reason on stderr.
//   fm-service-port-probe.mjs http <url> [<host-header>]
//       Prints the HTTP status code. Exit 0 on 2xx, exit 1 otherwise.
//       Bounded by FM_SERVICE_PORT_PROBE_TIMEOUT milliseconds (default 4000).
//
// Exit 2 is reserved for a usage error in every mode.

import net from "node:net";
import dns from "node:dns";
import http from "node:http";

// Errors that mean "this address is unusable here", never "someone else holds
// this port". Reporting one of these as a collision would send the caller
// walking a whole port window that could never have worked.
const ADDRESS_UNUSABLE = new Set(["EADDRNOTAVAIL", "EACCES", "EAFNOSUPPORT", "EINVAL"]);

function usage() {
  process.stderr.write(
    "Usage: fm-service-port-probe.mjs bind <addr> <port>...\n" +
      "       fm-service-port-probe.mjs resolve <hostname> <expected-ipv4>\n" +
      "       fm-service-port-probe.mjs http <url> [<host-header>]\n",
  );
}

function probeTimeoutMs() {
  const raw = Number(process.env.FM_SERVICE_PORT_PROBE_TIMEOUT);
  return Number.isInteger(raw) && raw > 0 ? raw : 4000;
}

// Bind, listen, and release one candidate. Resolves "free", "taken", or an
// unusable-address verdict carrying the concrete errno.
function tryBind(addr, port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    let settled = false;
    const finish = (verdict) => {
      if (settled) return;
      settled = true;
      resolve(verdict);
    };
    server.once("error", (error) => {
      const code = error && error.code ? error.code : "EUNKNOWN";
      if (code === "EADDRINUSE") {
        finish({ state: "taken" });
        return;
      }
      if (ADDRESS_UNUSABLE.has(code)) {
        finish({ state: "unusable", code });
        return;
      }
      finish({ state: "unusable", code });
    });
    server.once("listening", () => {
      // Close before reporting free, so the caller's own listen() is the next
      // thing to touch the port rather than queueing behind this probe.
      server.close(() => finish({ state: "free" }));
    });
    // exclusive:true keeps a clustered parent from handing this probe a shared
    // handle instead of a real bind, which would make the answer meaningless.
    server.listen({ host: addr, port, exclusive: true });
  });
}

async function bindMode(argv) {
  const addr = argv[0];
  const ports = argv.slice(1);
  if (!addr || ports.length === 0) {
    usage();
    return 2;
  }
  for (const raw of ports) {
    const port = Number(raw);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      process.stderr.write(`fm-service-port-probe: not a port: ${raw}\n`);
      return 2;
    }
    const verdict = await tryBind(addr, port);
    if (verdict.state === "free") {
      process.stdout.write(`${port}\n`);
      return 0;
    }
    if (verdict.state === "unusable") {
      process.stderr.write(
        `fm-service-port-probe: cannot bind ${addr} on this host (${verdict.code})\n`,
      );
      return 4;
    }
  }
  return 3;
}

async function resolveMode(argv) {
  const [hostname, expected] = argv;
  if (!hostname || !expected) {
    usage();
    return 2;
  }
  let records;
  try {
    records = await dns.promises.lookup(hostname, { family: 4, all: true });
  } catch (error) {
    const code = error && error.code ? error.code : "EUNKNOWN";
    process.stderr.write(`fm-service-port-probe: ${hostname} does not resolve (${code})\n`);
    return 1;
  }
  const addresses = records.map((record) => record.address);
  if (addresses.includes(expected)) return 0;
  process.stderr.write(
    `fm-service-port-probe: ${hostname} resolves to ${addresses.join(", ") || "nothing"}, not ${expected}\n`,
  );
  return 1;
}

function httpMode(argv) {
  const [url, hostHeader] = argv;
  if (!url) {
    usage();
    return Promise.resolve(2);
  }
  let target;
  try {
    target = new URL(url);
  } catch {
    process.stderr.write(`fm-service-port-probe: not a URL: ${url}\n`);
    return Promise.resolve(2);
  }
  if (target.protocol !== "http:") {
    process.stderr.write(`fm-service-port-probe: only http:// is probed: ${url}\n`);
    return Promise.resolve(2);
  }
  return new Promise((resolve) => {
    const headers = {};
    // An explicit Host header lets the caller address one specific server's
    // configured allowlist rather than whatever name happens to be in the URL.
    if (hostHeader) headers.Host = hostHeader;
    const request = http.request(
      {
        host: target.hostname,
        port: target.port || 80,
        path: `${target.pathname}${target.search}`,
        method: "GET",
        headers,
        timeout: probeTimeoutMs(),
      },
      (response) => {
        const status = response.statusCode || 0;
        response.resume();
        process.stdout.write(`${status}\n`);
        resolve(status >= 200 && status < 300 ? 0 : 1);
      },
    );
    request.once("timeout", () => {
      request.destroy(new Error("timed out"));
    });
    request.once("error", (error) => {
      process.stdout.write("-\n");
      process.stderr.write(
        `fm-service-port-probe: ${url} did not answer (${error && error.message ? error.message : error})\n`,
      );
      resolve(1);
    });
    request.end();
  });
}

async function main() {
  const [mode, ...rest] = process.argv.slice(2);
  if (mode === "bind") return bindMode(rest);
  if (mode === "resolve") return resolveMode(rest);
  if (mode === "http") return httpMode(rest);
  usage();
  return 2;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (error) => {
    process.stderr.write(`fm-service-port-probe: ${error && error.message ? error.message : error}\n`);
    process.exitCode = 2;
  },
);
