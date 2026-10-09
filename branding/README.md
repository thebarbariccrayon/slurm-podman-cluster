# Slurm-web Branding

NC State University logos and favicon for the Slurm-web gateway, set in the
`[ui]` section of `slurm_web_gateway` in `../docker-compose.yml`. The image
copies this directory to `/config/slurm-web-branding/`; `secrets-init` copies it
into the `slurm-web-branding` volume, mounted read-only in the gateway at
`/etc/slurm-web/branding/`. Rebuild (`make up`) after replacing a file.

| File                                     | Slot                          | Source (https://cdn.ncsu.edu/brand-assets/) |
|------------------------------------------|-------------------------------|---------------------------------------------|
| `logo_horizontal.png`, `_dark.png`       | Sidebar, 560×128 (2× of 280×64) | `logos/ncstate-type-4x1-wht-max.png`, scaled to 480 px wide and centred |
| `logo_login.png`, `_dark.png`            | Login page, 280×134 (2×)      | `logos/ncstate-brick-2x2-red-max.png`, scaled to 280 px wide |
| `favicon.ico`                            | Browser tab (16–256 px)       | `favicons/favicon.ico`, unchanged |

Regenerate the logos from the official files with ImageMagick:

    magick ncstate-type-4x1-wht-max.png -resize 480x -background none -gravity center -extent 560x128 PNG32:logo_horizontal.png
    magick ncstate-brick-2x2-red-max.png -resize 280x PNG24:logo_login.png

The NC State logo is a registered trademark. Follow
https://brand.ncsu.edu/designing-for-nc-state/logos-and-marks/: scale it only
uniformly, never recolor or redraw it, and keep it above the minimum on-screen
size (200 px wide for 4×1, 100 px for 2×2). Colors come from
https://brand.ncsu.edu/designing-for-nc-state/color/.
