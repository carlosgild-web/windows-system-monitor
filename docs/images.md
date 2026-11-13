# Images

The project's illustrations were made with **Google Gemini** (the free app at gemini.google.com). They are used
only around the data, never instead of it: the app icon, the "How this demo works" panel, the empty / paused /
error states in the console, and the README hero and social preview.

Nothing is fetched at runtime and the app never calls Gemini. **Every slot has a fallback**: a missing state
image shows its SVG icon, and a missing panel image is simply left out, so the app works without any of them.

| Image | Used in | File |
|---|---|---|
| App icon | Home-screen / bookmark icon (`apple-touch-icon`), README | `web/static/img/app-icon-512.png`, `app-icon-180.png` |
| Guide | Top of the "How this demo works" panel | `web/static/img/guide.webp` |
| No data / paused / error | Console empty states | `web/static/img/state-{nodata,paused,error}.webp` |
| Hero | Top of the README | `docs/images/hero.webp` |
| Social preview | GitHub repository card (uploaded in the repo settings) | `docs/images/social-preview.png` |

The browser tab icon stays `web/static/favicon.svg`: a vector icon is sharper than any image at 16 px.

## The prompts

Every prompt is in [`image_prompts.json`](image_prompts.json): one job per image, with shared style lines (palette
from the theme tokens, flat vector look, **no text or logos**). Spot illustrations also get a plain background
and a "readable at 80 px" line. To print the final prompt for each job:

```bash
python tools/prepare_images.py prompts
```

## Making them again

1. In the Gemini app, open **a new chat for each image** and paste its prompt.
2. Download the full-size image as `art/raw/<name>.png` (or `.jpg`/`.webp`), for example `art/raw/hero.png`. The
   `art/raw/` folder is git-ignored.
3. Run `python tools/prepare_images.py` (needs Pillow: `python -m pip install pillow`). It center-crops each image
   to its slot's shape, resizes it, and writes the files above. Use `--only hero guide` to redo just some.
4. Look at the result in the console (light and dark themes) and in the README. Regenerate any image that has
   garbled "text", a logo, or something that doesn't match its alt text.

The social preview is uploaded by hand: **repository Settings → General → Social preview → Edit → Upload an image**.
