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
- Everything shows on its production day. Whole muscle products have stages (see below), so one product appears on each of its stage days.
- Only Yehuda and Eli can change the plan (edit PIN).
- Chilli franks are split off the regular franks mix: enter the chilli kg inside the Franks line (2g/kg red spice extract + 2g/kg chilli flakes).
- Square aufschnitt and pepper/olive aufschnitt (olive variants) show a reminder on the previous working day to prep cubed salt beef (square: 9.5kg per 68.5kg; pepper/olive amount TBC).

## Stages

- Whole muscle lines have stages per product: salt beef and leanside chuck **Inject → Tumble (5–7 days) → Cook (next day)**; rauchfleisch **Brine → Smoke & sous vide (14 days)**; everything else **Inject → Cook (next day)**.
- On an Inject/Brine line, pick the next stage's day; the later stage lines are created automatically (even in a later week) and stay linked.

## Batch codes

`YYDDD-PP-N`: year, day of the year, product code, batch number of that product that day (one per tumbler batch). The code is set on the start day and carries through every stage. Chilli franks get their own `CF` code. Staff type the code into **Batch Number** in FOOD.LOG.

## Weigh-outs and tick lists

- **Weigh-out sheet**: the day's ingredients in grams, scaled to the planned kg, split per batch over 150kg. One shared brine card per brine type with a top-up box. Shows added nitrite (mg/kg) and flags anything over 150.
- **Tick lists**: one per batch (and one per brine): staff, probe ID, intake temp (<8°C or reject + note), every ingredient and method step with a tick box, FOOD.LOG program and start time, cooling temps, target weights. Saved to the sheet's `Records` tab as you type. Print button for paper.
- **Make report** (Yehuda/Eli only): builds the week's HACCP PDFs now.
- Recipes and method steps live in the sheet's `Recipes` tab (imported from CSV), never in this repo:
  `Product id | Recipe | Stage | Ingredient / step | Amount (g) | For (kg) | Note | Check`

## Weekly HACCP report

Every Friday 10:00 Google makes one PDF for the whole week plus one per product from the tick list records, saves them in Drive (`Deli HACCP Reports/w-c <date>`) and emails them to `REPORT_EMAILS`. Runs on Google's servers, so no PC needs to be on.

## Backend setup (once)

1. Create a Google Sheet called `Deli Planner`.
2. Extensions > Apps Script. Delete the sample code, paste in `apps-script/Code.gs`, save.
3. Project Settings (cog) > Script properties > add:
   - `DEVICE_KEY` – a long random phrase
   - `EDIT_PIN` – the PIN for Yehuda and Eli
   - `REPORT_EMAILS` – comma-separated addresses for the weekly report
   - `STAFF` – comma-separated names for the tick list Staff dropdown
4. Deploy > New deployment > type **Web app**. Execute as: **Me**. Who has access: **Anyone**. Deploy, authorise, copy the Web app URL (ends `/exec`).
5. Open the planner, tap **Settings**, paste the URL, enter the device key (and the PIN on editors' devices only).

Project Settings > Time zone: (GMT+00:00) London. Then in the editor choose `installFridayTrigger` in the function list and press **Run** once (approve the permissions) to switch on the Friday 10:00 report.

After any change to `Code.gs`: Deploy > Manage deployments > edit (pencil) > Version: **New version** > Deploy. The URL stays the same.
