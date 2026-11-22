# FiveLoop – looper πέντε καναλιών για iPad

Αυτόνομος live looper για iPad (iPadOS 15+, landscape), με λειτουργία βασισμένη στο BOSS RC-505mkII.
Πέντε στερεοφωνικά tracks με συγχρονισμό, εφέ εισόδου και track (4 banks × 4), rhythm, mixer, 99 μνήμες,
MIDI και εξαγωγή WAV. Χωρίς internet και χωρίς cloud.

> Δεν έχει σχέση με τη Roland/BOSS. Δεν περιέχει κώδικα, firmware, samples ή γραφικά τους.
> Ο ήχος των εφέ και τα drums είναι δική μας υλοποίηση, όχι αντιγραφή.

## Τι περιέχει ο φάκελος

| Φάκελος | Περιεχόμενο |
|---|---|
| `Packages/LooperCore/` | Η μηχανή ήχου: loop tracks, συγχρονισμός, undo/redo, εφέ, rhythm, MIDI, μνήμες, WAV, offline render. Καθαρή Swift, με 31 αυτόματα tests |
| `App/Sources/` | Η εφαρμογή iPad: RemoteIO (ήχος χαμηλής καθυστέρησης), CoreMIDI, οθόνες SwiftUI |
| `project.yml` | Περιγραφή του Xcode project (το project φτιάχνεται με XcodeGen) |
| `.github/workflows/build.yml` | Χτίζει την εφαρμογή σε Mac του GitHub και βγάζει αρχείο `.ipa` |
| `docs/SPEC.md` | Τεχνική προδιαγραφή (Φάση 1) και αντιστοίχιση με τις παραμέτρους του manual |
| `docs/TEST_RESULTS.md` | Αποτελέσματα των αυτόματων tests και της μέτρησης απόδοσης |
| `docs/TEST_PLAN.md` | Λίστα χειροκίνητων δοκιμών στο iPad |

## Εγκατάσταση στο iPad από Windows (χωρίς Mac)

### 1. Χτίσιμο στο GitHub (μία φορά, και μετά σε κάθε αλλαγή)
1. Φτιάξε δωρεάν λογαριασμό στο github.com.
2. Φτιάξε νέο repository (π.χ. `fiveloop`). Αν είναι **public**, τα λεπτά macOS του GitHub Actions είναι δωρεάν.
   Αν είναι private, το δωρεάν όριο είναι μικρό (τα λεπτά macOS μετράνε περισσότερο).
3. Ανέβασε όλα τα αρχεία του φακέλου (Add file → Upload files, ή με GitHub Desktop).
   Ο φάκελος `.github` πρέπει να ανέβει κι αυτός. Το GitHub Desktop τον ανεβάζει αυτόματα.
4. Στην καρτέλα **Actions** ξεκινά το “Build iPad app” (ή πάτα *Run workflow*). Διαρκεί περίπου 10 λεπτά.
5. Όταν βγει πράσινο ✓, κατέβασε από το κάτω μέρος της σελίδας το artifact **FiveLoop-unsigned-ipa**.
   Είναι zip που περιέχει το `FiveLoop-unsigned.ipa`.
   Αν βγει κόκκινο ✗, κατέβασε το artifact **build-logs** και στείλε μου το `xcodebuild.log`.

### 2. Εγκατάσταση με Sideloadly
1. Εγκατάστησε το iTunes και το iCloud **από το site της Apple**, όχι από το Microsoft Store.
2. Εγκατάστησε το Sideloadly (sideloadly.io).
3. Σύνδεσε το iPad με καλώδιο USB, ξεκλείδωσέ το και πάτα “Trust/Εμπιστοσύνη”.
4. Στο Sideloadly: σύρε μέσα το `.ipa`, γράψε το Apple ID σου και πάτα **Start**.
   Καλό είναι να χρησιμοποιήσεις δεύτερο Apple ID μόνο για αυτό.
5. Στο iPad: Ρυθμίσεις → Γενικά → Διαχείριση VPN και συσκευών → το Apple ID σου → **Εμπιστοσύνη**.
6. Με δωρεάν Apple ID η εφαρμογή **λήγει σε 7 μέρες**. Τότε ξανακάνεις το βήμα 4· οι μνήμες σου μένουν.
   Με πληρωμένο λογαριασμό developer (99 $/έτος) η εφαρμογή κρατάει έναν χρόνο.

### Αν έχεις Mac
`brew install xcodegen && xcodegen generate`, άνοιξε το `FiveLoop.xcodeproj`, διάλεξε την ομάδα σου στο
Signing και πάτα Run με συνδεδεμένο το iPad.

## Γρήγορη χρήση
- **REC/PLAY** (μεγάλο στρογγυλό κουμπί): εγγραφή → overdub → αναπαραγωγή, όπως στο μηχάνημα
  (REC ACTION στην οθόνη AUDIO). Κόκκινο = εγγραφή, κίτρινο = overdub, πράσινο = αναπαραγωγή.
  Όταν αναβοσβήνει, περιμένει την αρχή του μέτρου.
- Η **πρώτη εγγραφή** ορίζει το tempo. Τα επόμενα tracks συγχρονίζονται στο μέτρο (QUANTIZE, MEASURE AUTO).
- **STOP**: πάτημα για stop (με STOP MODE), δεύτερο πάτημα για άμεσο stop. Το **CLEAR** είναι στο TRACK
  (ζητάει επιβεβαίωση).
- **Input/Track FX**: τα κουμπιά A–D ανοιγοκλείνουν το εφέ. Το εικονίδιο κάτω από κάθε κουμπί ανοίγει τις παραμέτρους.
- **WRITE**: αποθήκευση στη μνήμη. Αυτόματο backup γίνεται μετά από κάθε εγγραφή και όταν η εφαρμογή
  πάει στο background.
- Χρησιμοποίησε **ακουστικά**. Με το ηχείο του iPad το monitoring κλείνει αυτόματα για να μη σφυρίζει.
- **AUDIO → LATENCY ADJ**: ρύθμισε ώστε οι εγγραφές να πέφτουν ακριβώς στο ρυθμό (βλ. TEST_PLAN #25).

## Κατάσταση (τι έχει γίνει και τι λείπει)

**Λειτουργεί και έχει ελεγχθεί με αυτόματα tests (μηχανή ήχου):** 5 tracks, εγγραφή, overdub,
replace, undo/redo, reverse, one-shot, speed ½/×2, tempo sync (pitch), loop sync, quantize, AUTO/FREE
measure, start/stop modes και fades, single/multi play, bounce, auto-rec, count-in, αντιστάθμιση
latency, χωρίς drift (δοκιμή 30 λεπτών), mixer, master comp/reverb, 26 εφέ, rhythm (61 patterns × 4
variations, 16 kits), MIDI clock in/out, learn, 99 μνήμες, import/export, backup, crash recovery,
mixdown/stems.

**Γραμμένο αλλά όχι ακόμα δοκιμασμένο σε iPad:** η εφαρμογή iOS (ήχος RemoteIO, CoreMIDI, οθόνες).
Από αυτό το περιβάλλον δεν μπορεί να γίνει compile για iOS. Η πρώτη επιβεβαίωση θα έρθει από το
GitHub build, και είναι πιθανό να χρειαστούν μερικές διορθώσεις.

### Περιορισμοί / επόμενες φάσεις
- **Εφέ:** 26 από τους 55 τύπους του manual. Λείπουν: SYNTH, G2B, SUSTAINER, AUTO RIFF, SLOW GEAR,
  TRANSPOSE, PITCH BEND, ROBOT, ELECTRIC, HRM MANUAL/AUTO, VOCODER, OSC VOC/BOT, PREAMP, OCTAVE,
  STEREO ENHANCE, STEP SLICER, REVERSE/MOD/GRANULAR DELAY, WARP, TWIST, GATE/REVERSE REVERB,
  BEAT SCATTER/SHIFT. Λείπει επίσης το FX SEQUENCE. Η παράμετρος RATE με σύνθετες τιμές
  νότας του hardware έχει απλοποιηθεί σε SYNC + RATE.
- **TEMPO SYNC MODE XFADE** (αλλαγή tempo χωρίς αλλαγή pitch, δηλαδή time-stretch): δεν υπάρχει ακόμα.
  Σε αλλαγή tempo αλλάζει και ο τόνος (MODE = PITCH).
- **Overdub** γίνεται μόνο όταν το track παίζει στην αρχική του ταχύτητα (όχι σε reverse, ½/×2 ή αλλαγμένο tempo).
- Το **SPEED CHANGE / SYNC ADJUST** εφαρμόζεται πάντα άμεσα.
- Το **BOUNCE IN** έχει καθυστέρηση ενός audio block (~6 ms).
- Το **Rhythm** έχει δικά του patterns και ήχους, όχι τα 200+ πρωτότυπα του μηχανήματος. Δεν υπάρχουν
  ακόμα USER patterns, INTRO/ENDING και VAR.CHANGE LOOP END.
- Ένα **import WAV** σταματά την αναπαραγωγή όσο φορτώνει.
- **Μνήμη:** 60 δευτερόλεπτα ανά track (αλλάζει σε 30–180 s, με επανεκκίνηση). Τα 60 s πιάνουν περίπου
  210 MB για τα 5 tracks μαζί με το undo. Σε iPad με 2 GB RAM καλύτερα μέχρι 60 s.
- Οι έξοδοι MAIN/SUB του hardware δεν υπάρχουν στο iPad. Όλα βγαίνουν στη στερεοφωνική έξοδο.
- Η αναγνώριση MIDI CC του μηχανήματος έχει αντικατασταθεί από το σύστημα ASSIGN/LEARN. Το
  Program Change επιλέγει μνήμη.
- Η απόδοση σε παλιό iPad πρέπει να μετρηθεί στη συσκευή (οθόνη DIAG).
