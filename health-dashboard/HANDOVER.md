# Health-dashboard og NOOP Food: overdragelse (26. nov. 2026)

## Du skal svare på (2 spørgsmål)

1. **Udseende: A, B eller C?** Det nuværende look (neon-mint på mørk navy, ens afrundede kasser) virker AI-genereret.
   - **A. iPhone (min anbefaling):** ligner Apple Health og NOOP-appen. Sort eller hvid baggrund, iPhone-blå, fed systemskrift.
   - **B. Journal:** som en patientjournal med hvidt papir og blåsort tekst. Pulsgrafen står på EKG-papirets lyserøde gitter.
   - **C. Instrument:** gråtoner, tal i skrivemaskineskrift, skarpe hjørner. Farve kun hvor den betyder noget.
2. **Fire faner i bunden i stedet for syv øverst? Ja eller nej.**
   - **I dag:** + Log, dagens medicin, det der er i gang, søvn og recovery.
   - **Kalender:** måneden med alle markører, historik og eksport til lægen.
   - **Indsigt:** Trends og Patterns lagt sammen.
   - **Medicin:** daglig medicin, medicin efter behov og dage du sprang over.

Svar for eksempel "A ja".

## Du skal gøre (når det passer)

- Når mailen om `v12.0.0-extras.5` kommer: GitHub → Releases → Edit → sæt flueben ved "Set as the latest release" → gem.
- Når extras.5 er på telefonen: swipe et måltid væk og tryk Undo. Det er den eneste rettelse, jeg ikke har kunnet teste på en rigtig telefon.
- Valgfrit: GitHub → Watch → Custom → Releases, så du får mail om nye builds.

## Problemer fra brugertesten (ikke rettet endnu)

En agent brugte dashboardet som dig på en telefon, på en kopi af dine data.

1. ✅ **Rettet:** tidspunkter efter midnat havnede i fremtiden. Et tidspunkt senere end nu gemmes nu som i går, og en dato efter i dag afvises.
2. **Tingene ender forskellige steder uden system.** Medicin står under Medicine og på dagssiden. Migræne og sygdom står i Record. Blodtryk står kun på dagssiden og i Trends. Forslag: én samlet historik over alt, du logger, med filtre.
3. **Migræne er delt i to bokse.** En igangværende står i "Going on", en afsluttet i sit eget kort. Den igangværende viser ikke den medicin, du har taget. Forslag: ét migrænekort med tider, styrke og medicin.
4. **"Going on" blander alt sammen:** migræne, daglig medicin og forkølelse. Forslag: del det op i "Dagens medicin" (tjekliste) og "I gang".
5. **Fluebenet for daglig medicin er omvendt.** Grønt ✓ betyder taget, og du trykker for at sige, at du sprang over. Hvilke dage du sprang over, kan du ikke se. Forslag: vis dem i kalenderen og som en liste.
6. **Kalenderen mangler blodtryk og sprunget medicin.** 3 dages sygdom ser ud som 3 løse prikker. Forslag: flere markører, og sygdom som én sammenhængende streg.
7. **Patterns viser kun tomme kort,** også for en medicin, du startede i går. Forslag: skjul kortene, indtil der er nok dage.
8. **Syv menupunkter går over to linjer på telefonen.** Se spørgsmål 2.

Mindre ting:
- "Took medicine" findes to steder (Log-menuen og migrænerækken), og knapperne ser ens ud.
- Når du tilføjer medicin, er "Now and then" valgt som standard, ikke "Every day".
- "Deleted. Undo" står øverst på siden og er let at overse.
- Når du er på en tidligere dag, er "Calendar" markeret i menuen, ikke "Today".

## Lavet i denne omgang

- **Mappen:** projekterne er delt op i `meowmind/`, `Noop2/`, `Proxmox_fix/` og `skole_hjerne/`.
- **NOOP-appen** (på `main`, kommer med extras.5):
  - Fortryd ved sletning af et måltid.
  - Restore synker først, så den ikke sletter måltider, der ikke er sendt.
  - Fotos hentes tilbage efter en restore.
- **CI:** commits, der kun ændrer `.md`-filer, starter ikke Mac-tests. Annullerede builds giver besked.
- **Server (CT 113):**
  - Nyt endpoint `GET /photos/{id}`.
  - Backup kopieres hver nat kl. 03:45 til HDD'en (`/srv/media/backups/health`) og gemmes i 30 dage. Restore er testet.
- **Dashboard:**
  - Recovery-ring og "normalt for dig"-barer.
  - Linje med seneste sync.
  - Kalender farvet efter recovery.
  - Søvn som stablede søjler og recovery som farvede søjler.
  - ▲▼ i grøn eller rød på "This week vs last".
  - Patterns som fremdriftskort.
  - Menuen kan ses på mobil.

## Til næste gang

- Serverkoden på CT 113 ligger ikke i git. Den gamle kode gemmes ved hvert deploy i `/root/health-code-*.tgz`. Mit forslag er at sætte git op (cirka 10 min).
- To preview-containere kører på CT 113: `health-preview` på 8099 og `health-design` på 8098. De kan kun nås inde fra CT'en og bruger en kopi af databasen. Designforslagene ligger i `/opt/health-design/health/static/theme-*.css`.
- `meowmind/` har en ændring i `meowmind/calendars.py`, som ikke er committet, og ligger 6 commits foran origin. Det er ikke fra denne session.
