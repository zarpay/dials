# dials docs

The VitePress documentation site for the [`dials`](../gem) gem.

**Read it hosted: <https://zarpay.github.io/dials/>**

The site is built and deployed to GitHub Pages automatically on every push
to `main` by [`.github/workflows/docs.yml`](../.github/workflows/docs.yml).

## Working locally

```bash
npm install
npm run dev       # http://localhost:3000/dials/  (note the /dials/ base path)
npm run build     # must pass before merging docs changes
npm run preview   # serve the production build locally
```

## Layout

| Path | Contents |
|---|---|
| `index.md` | Landing page |
| `getting-started/` | Quick start |
| `concepts/` | The dial model, variants/scopes, caching, change log, pattern boundary |
| `guides/` | Install, retrofits, write surface, testing |
| `design/` | Design decisions and comparisons to alternatives |
| `reference/` | API reference |
| `.vitepress/` | Site config and theme |
