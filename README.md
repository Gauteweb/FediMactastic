# FediMactastic

macOS-utgaven av [Feditastic](https://github.com/Gauteweb/Feditastic), en klient for Fediverset
(Pleroma, Akkoma, GoToSocial og Mastodon). Den har samme funksjoner og samme utseende som
Android-appen: fem fargetemaer med skarpe hjørner og tynn kantlinje, bakgrunnsbildet med slør,
toppfelt og bunnmeny (Hjem · Bilder · Varsler · Søk · Skriv · Profil). Grensesnittet er på norsk
(bokmål) når macOS bruker norsk, ellers på engelsk.

## Installere med Homebrew

```bash
brew install gauteweb/tap/fedimactastic
open "$(brew --prefix fedimactastic)/FediMactastic.app"
```

Homebrew bygger appen fra kildekoden (krever Command Line Tools). Vil du ha den i Launchpad og
Spotlight, kan du lage en snarvei:

```bash
mkdir -p ~/Applications && ln -sf "$(brew --prefix fedimactastic)/FediMactastic.app" ~/Applications/
```

## Bygge og starte

Krever macOS 14 eller nyere og bare **Command Line Tools** (ikke hele Xcode):

```bash
./build-app.sh             # bygger FediMactastic.app
open FediMactastic.app
./build-app.sh --install   # bygger og kopierer appen til ~/Applications
```

`CONFIG=debug ./build-app.sh` gir et debug-bygg.

## Funksjoner

Alt fra Android-appen, unntatt det som er Android-spesifikt (snarveier på app-ikonet) og
push-varsler/timesoppsummering:

- Innlogging med OAuth på instansens egen side, flere brukere, «Bytt bruker» og «Legg til bruker».
- Tidslinjer: Hjem, lokal feed, fødererte innlegg og egne lister (velg i «Hjem ▾»), emneknagger,
  tråder, profiler med felt, roller, bot-merke, «Alle innlegg / Kun media», følg og lister.
- Fanen «Bilder»: bare innlegg med bilder/video, bildet først, flere bilder blas sidelengs.
- Kort med lenkeforhåndsvisning, avstemninger, innholdsvarsel, «Vis alt» for lange innlegg,
  «via <app>», grønn bakgrunn for svar og omtaler til deg, egendefinerte emojier og animerte GIF-er.
- Svar, del, favoritt, bokmerke, kopier lenke, åpne i nettleser, rediger, slett og fremhev på profilen.
- Skriv: synlighet, innholdsvarsel, opptil 4 bilder/videoer med alt-tekst (også dra-og-slipp),
  Markdown med knapper og hjelp, emojivelger, @-forslag og språk (nn, nb, en).
- Varsler med filter «Alle / Svar» og «X nye varsler».
- Søk etter @brukere og #emneknagger.
- Bildevisning med zoom (klyp, dobbeltklikk), bla med piltastene og alt-tekst.
- Video i feeden, GIF-video i loop uten lyd.
- Matrix-chat (Cinny på chat.gaute.space) i appens farger, «Om»-siden og helsestatus for instansen.

### Mac-tilpasninger

| Android | Mac |
|---|---|
| Hold inne et ikon i bunnmenyen | Verktøytips når du holder pekeren over |
| Sveip mellom faner | ⌘1–⌘5 (menyen «Gå») |
| Dra ned for å oppdatere | ⌘R, eller dobbeltklikk på fanen |
| Tilbake-knappen | Pilen i toppfeltet eller ⌘[ |
| Snarvei «Nytt innlegg» | ⌘N |
| Publiser | ⌘↩ i skrivevinduet |

Egendefinerte emojier i tekst vises som stillbilder (animerte GIF-er spilles av i bilder og profilbilder).

## Struktur

Kildekoden ligger i `Sources/FediMactastic/` og følger Android-appen fil for fil:

- `Models.swift`, `Json.swift`, `ApiClient.swift`, `SessionStore.swift` – data, API og lagring
- `ViewModels.swift`, `Auth.swift`, `AppState.swift` – tilstand (tilsvarer `vm/` og `Graph`)
- `MainView.swift` – navigasjon, toppfelt og bunnmeny
- `StatusCard.swift`, `Screens.swift`, `Compose.swift`, `Dialogs.swift` – skjermene
- `HtmlParse.swift`, `RichText.swift` – HTML fra instansen til tekst med lenker og emojier
- `Images.swift`, `Video.swift`, `ImageViewer.swift`, `WebViews.swift` – medier, chat og «Om»
- `Theme.swift` – de fem temaene med nøyaktig samme farger som Android
- `StringsTable.swift` – tekstene, generert fra Android-appens `strings.xml`

`Support/` har Info.plist, app-ikonet (`make-icon.swift` tegner det) og bakgrunnsbildet.

macOS 27-SDK-et har gjort `@State` om til en makro som Command Line Tools mangler plugin for.
Koden bruker derfor aliaset `@ViewState` (se `Theme.swift`), som virker med alle SDK-er.

## Personvern

Ingen sporing. Appen snakker bare med instansen du velger (og chat.gaute.space hvis du åpner chatten).
Innloggingen lagres lokalt i appens innstillinger på Macen.

## Lisens

Copyright © 2026 Gaute Holmin. GPL-3.0-or-later, samme som Feditastic (se `LICENSE`).
Bakgrunnsbildet er tatt av Gaute Holmin og har samme lisens.
