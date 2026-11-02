# Deli Planner

Weekly production planner for the MH Meats deli: plan each product by day, then (coming next) ingredient weigh-outs and HACCP tick lists.

- **App:** `index.html`, hosted on GitHub Pages.
- **Data:** a Google Sheet behind a Google Apps Script web app (`apps-script/Code.gs`).
- **No recipes or secrets in this repo.** The repo is public. Recipe quantities will live in the Google Sheet. The API address, device key and edit PIN are typed into each device once and stay on that device.

## Planning rules

- **Minced products** (salami, sausage, aufschnitt): quantity = kg of meat block (meat + skin + water + ice + fat).
- **Whole muscle products**: quantity = kg of green weight (before injection).
- All recipe ingredient amounts are shown in grams (e.g. 4.65kg → 4650g). Liquids by weight in grams too.
- Recipes scale exactly. Over 150kg (tumbler max) splits into equal batches of 150kg or less.
- Everything shows on its production day. Whole muscle products have a stage, so one product can appear on its brine/inject day and again on its prep & cook day.
- Only Yehuda and Eli can change the plan (edit PIN).
- Chilli franks are split off the regular franks mix: enter the chilli kg inside the Franks line (2g/kg red spice extract + 2g/kg chilli flakes).
- Square aufschnitt and pepper/olive aufschnitt (olive variants) show a reminder on the previous working day to prep cubed salt beef (square: 9.5kg per 68.5kg; pepper/olive amount TBC).

## Weigh-outs

- The **Weigh-out sheet** button (next to "Planned only") shows the selected day's ingredients in grams, scaled to the planned kg, split per batch when over 150kg, with a Print button.
- Recipes live in the Google Sheet's `Recipes` tab (created automatically), one row per ingredient:
  `Product id | Recipe | Stage | Ingredient | Amount (g) | For (kg) | Note`
  - **Recipe** blank = applies to every recipe of that product; `Chilli` = the chilli franks add-on (scaled to the chilli kg only).
  - **Stage** blank for minced products; `Brine / inject` or `Prep & cook` for whole muscle.
  - **Amount (g)** is for the **For (kg)** weight, exactly as on the recipe sheet (e.g. salt 4650 for 150).
- A product with no rows shows "Recipe not loaded yet".

## Backend setup (once)

1. Create a Google Sheet called `Deli Planner`.
2. Extensions > Apps Script. Delete the sample code, paste in `apps-script/Code.gs`, save.
3. Project Settings (cog) > Script properties > add:
   - `DEVICE_KEY` – a long random phrase
   - `EDIT_PIN` – the PIN for Yehuda and Eli
4. Deploy > New deployment > type **Web app**. Execute as: **Me**. Who has access: **Anyone**. Deploy, authorise, copy the Web app URL (ends `/exec`).
5. Open the planner, tap **Settings**, paste the URL, enter the device key (and the PIN on editors' devices only).

After any change to `Code.gs`: Deploy > Manage deployments > edit (pencil) > Version: **New version** > Deploy. The URL stays the same.
