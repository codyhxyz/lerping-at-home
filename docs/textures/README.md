# Adding textures (agent workflow)

The viewer at https://codyhxyz.github.io/lerping-at-home/ renders from
`manifest.json` in this folder. No build step — GitHub Pages serves `docs/`
directly and rebuilds about a minute after each push to `main`.

## Add a texture

1. Put the render in this folder: `docs/textures/<name>.jpg` or `.png`.
   Prefer 16:9 or square, sRGB, under ~2 MB.
2. Add an entry to `manifest.json` under the right pack's `textures` array:
   ```json
   {
     "name": "Molten Vein",
     "image": "textures/molten-vein.jpg",
     "shader": "liquid-metal",
     "description": "One line on what it is and how it was tuned."
   }
   ```
   `image` is relative to the site root (`docs/`), so renders in this folder
   use the `textures/` prefix.
3. Push to `main`. The site picks it up automatically.

## Start a new pack

Add another object to the top-level `packs` array with `id`, `name`,
`description`, and a `textures` array. Each pack renders as its own section.
