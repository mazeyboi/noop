# NOOP Food: overdragelse (nat til 25. nov. 2026)

## Du skal tjekke (2 ting)

1. Åbn https://github.com/mazeyboi/noop/releases. Står `v12.0.0-extras.4` der: Edit → flueben i "Set as the latest release" → gem. Den lander på telefonen inden for 6 timer på hjemme-wifi.
2. Står den der ikke: åbn https://github.com/mazeyboi/noop/actions, vælg den røde kørsel, tryk "Re-run failed jobs". (GitHub manglede Mac-maskiner i nat; det er ikke en kodefejl.)

Når den er på telefonen: prøv Photo (åbner kameraet selv?) og swipe på et gemt måltid. Det er de to ting, jeg er mindst sikker på, fordi jeg ikke kunne køre appen.

## Hvad jeg gjorde

- Læste Food-koden (`Packages/NOOPExtras`), serveren (CT 113 `health`) og installationskæden (VM 112 `noop-signing`). Serverne er kun læst, intet ændret.
- Rettede Food i iOS-appen, merge `e1d5a096` på `main`:
  - Gem af mål, drikke, AI provider og gemt måltid viser nu "Saved." eller fejlen.
  - Mål-skærmen siger, når intet er gemt endnu.
  - Sync viser hvornår den sidst lykkedes. Kun én "Sync now" i indstillinger.
  - Foto åbner kameraet direkte. Et dårligt estimat kan kasseres på tjek-skærmen.
  - "Clear list" og "Reset to defaults" spørger først.
  - Egne fødevarer kan rettes og slettes, gemte måltider omdøbes, drikke tilføjes og fjernes.
  - Favorit gemmes med det samme.
- GitHub Actions var slået fra på forken siden 21. nov. Du slog det til igen.

## Beslutninger jeg tog

- Sprog er uændret engelsk: resten af NOOP findes ikke på dansk, så Food passer allerede til appen.
- Serveren er ikke rørt: der var ingen fejl i loggen, og rettelserne krævede det ikke.
- Lokal klon: `C:\Users\dowling\Documents\extile_claude\Noop2` (branch `main`, arbejdsbranch `extras/v2`).

## Ikke gjort

- Udseendet er ikke vurderet. Send 3-5 skærmbilleder af Food, så tager jeg det derfra.
- Foto → AI-estimat har aldrig været brugt for alvor (serveren har 0 fotos), så den del er kun vurderet ud fra koden.
- Tre upstream-pakketest blev annulleret af GitHub (ingen ledige Mac-maskiner). Alt i Food var grønt.
