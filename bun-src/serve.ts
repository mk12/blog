// Copyright 2023 Mitchell Kember. Subject to the MIT License.

Bun.serve({
  fetch(request) {
    const url = new URL(request.url);
    return new Response("Hello!");
  },
});
