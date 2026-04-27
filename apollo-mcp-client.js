#!/usr/bin/env node

import https from "https";
import http from "http";
import { URL } from "url";

const CLIENT_ID = "G64sNtsNTCRcNV9feUElpf00mO9bwpkg";
const CLIENT_SECRET =
  "a6opiEn3rzmQStx5ymy04d9w2w9RkZNClNomXxzHo5ngI06aPcVpVWk0bR-6T4Ek";
const TOKEN_URL = "https://dev-2rd4k1xxfpjky67u.us.auth0.com/oauth/token";
const AUDIENCE = "http://localhost:8000/mcp-example";
const MCP_URL = "http://127.0.0.1:8000/mcp";

let accessToken = null;

// Get access token
async function getToken() {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({
      grant_type: "client_credentials",
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      audience: AUDIENCE,
    });

    const url = new URL(TOKEN_URL);
    const options = {
      hostname: url.hostname,
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": data.length,
      },
    };

    const req = https.request(options, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        try {
          const result = JSON.parse(body);
          resolve(result.access_token);
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

// Send MCP request via SSE
async function sendMCPRequest(message) {
  const url = new URL(MCP_URL);
  const data = JSON.stringify(message);

  const options = {
    hostname: url.hostname,
    port: url.port,
    path: url.pathname,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      Authorization: `Bearer ${accessToken}`,
      "Content-Length": data.length,
    },
  };

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Request timeout"));
    }, 10000); // 10 second timeout

    const req = http.request(options, (res) => {
      let buffer = "";
      let resolved = false;

      res.on("data", (chunk) => {
        buffer += chunk.toString();

        // Parse SSE events line by line
        const lines = buffer.split("\n");

        for (let i = 0; i < lines.length - 1; i++) {
          const line = lines[i];
          if (line.startsWith("data: ")) {
            try {
              const jsonData = JSON.parse(line.slice(6));
              if (!resolved) {
                clearTimeout(timeout);
                resolved = true;
                resolve(jsonData);
              }
            } catch (e) {
              console.error("Failed to parse SSE data:", e.message);
            }
          }
        }

        // Keep the last incomplete line
        buffer = lines[lines.length - 1];
      });

      res.on("end", () => {
        if (!resolved) {
          clearTimeout(timeout);
          if (buffer.startsWith("data: ")) {
            try {
              const jsonData = JSON.parse(buffer.slice(6));
              resolve(jsonData);
            } catch (e) {
              reject(new Error("Failed to parse final SSE message"));
            }
          } else {
            reject(new Error("No valid response received"));
          }
        }
      });

      res.on("error", (error) => {
        if (!resolved) {
          clearTimeout(timeout);
          reject(error);
        }
      });
    });

    req.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });

    req.write(data);
    req.end();
  });
}

// Main stdio loop
async function main() {
  console.error("Getting access token...");
  accessToken = await getToken();
  console.error("Connected to Apollo MCP Server");

  // Read from stdin and send to MCP server
  process.stdin.setEncoding("utf8");
  let inputBuffer = "";

  process.stdin.on("data", async (chunk) => {
    inputBuffer += chunk;

    // Process complete JSON messages (one per line)
    const lines = inputBuffer.split("\n");
    inputBuffer = lines.pop(); // Keep incomplete line

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const message = JSON.parse(line);
        console.error(
          `Received: ${message.method || "response"} (id: ${
            message.id || "none"
          })`
        );

        // Handle notifications (no response expected)
        if (message.method && message.method.startsWith("notifications/")) {
          console.error(`Skipping notification: ${message.method}`);
          continue;
        }

        // Handle regular requests
        if (message.method) {
          try {
            const response = await sendMCPRequest(message);
            console.error(`Sending response for id: ${message.id}`);
            process.stdout.write(JSON.stringify(response) + "\n");
          } catch (error) {
            console.error(`Error: ${error.message}`);

            // Send error response
            const errorResponse = {
              jsonrpc: "2.0",
              id: message.id,
              error: {
                code: -32603,
                message: error.message,
              },
            };
            process.stdout.write(JSON.stringify(errorResponse) + "\n");
          }
        }
      } catch (error) {
        console.error("Failed to parse message:", error.message);
      }
    }
  });

  process.stdin.on("end", () => {
    console.error("stdin closed, exiting");
    process.exit(0);
  });
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
