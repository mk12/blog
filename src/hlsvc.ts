// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { Socket } from "bun";
import { eat } from "./util";

const socketPath = "hlsvc.sock";

// Client bindings for the hlsvc server.
export class HlsvcClient {
  private state:
    | { mode: "init" }
    | { mode: "connecting"; promise: Promise<Socket> }
    | { mode: "connected"; socket: Socket };
  private interests: Deferred<string>[] = [];

  constructor() {
    this.state = { mode: "init" };
  }

  // Highlights code as the given language.
  async highlight(lang: string, code: string): Promise<string> {
    const interest = new Deferred<string>();
    this.interests.push(interest);
    (await this.socket()).write(`${lang}:${code}\0`);
    return interest.promise;
  }

  // Closes the connection. This must be called or the program will hang.
  close(): void {
    if (this.state.mode === "connecting") {
      throw Error("cannot close socket in the middle of connecting");
    }
    if (this.state.mode === "connected") this.state.socket.end();
  }

  private async socket(): Promise<Socket> {
    switch (this.state.mode) {
      case "init": {
        const deferred = new Deferred<Socket>();
        this.state = { mode: "connecting", promise: deferred.promise };
        const onSuccess = (socket: Socket) => {
          this.state = { mode: "connected", socket };
          deferred.resolve(socket);
        };
        this.connect(socketPath, onSuccess, deferred.reject);
        return this.state.promise;
      }
      case "connecting":
        return this.state.promise;
      case "connected":
        return this.state.socket;
    }
  }

  private connect(
    path: string,
    onSuccess: (s: Socket) => void,
    onFailure: (e: Error) => void
  ): void {
    let buffer = "";
    Bun.connect({
      unix: path,
      socket: {
        binaryType: "uint8array",
        open: (socket) => onSuccess(socket),
        data: (_socket, data: Uint8Array) => {
          buffer += new TextDecoder().decode(data);
          let idx;
          while ((idx = buffer.indexOf("\0")) >= 0) {
            this.handleResponse(buffer.slice(0, idx));
            buffer = buffer.slice(idx + 1);
          }
        },
        error: (_socket, error) => {
          this.nextInterest().reject(error);
        },
      },
    }).catch(onFailure);
  }

  private handleResponse(raw: string): void {
    const interest = this.nextInterest();
    const error = eat(raw, "error:");
    if (error) {
      interest.reject(new Error(`server responded with error: ${error}`));
    } else {
      interest.resolve(raw);
    }
  }

  private nextInterest(): Deferred<string> {
    const next = this.interests.shift();
    if (next === undefined) throw Error("no pending request");
    return next;
  }
}

// A promise that can be resolved or rejected from the outside.
class Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = Deferred.unset;
  reject: (error: Error) => void = Deferred.unset;

  private static unset() {
    throw Error("unreachable since Promise ctor runs callback immediately");
  }

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}
