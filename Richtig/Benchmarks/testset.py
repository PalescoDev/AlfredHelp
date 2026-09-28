"""Testdaten für den AlfredHelp-Modellbenchmark.

Alle Referenzen sind handgeschrieben und bilden den tatsächlichen Einsatzfall ab:
Meeting-/Call-Sprache, kurze Sätze, Fachbegriffe, Rückfragen.
"""

# ---------------------------------------------------------------------------
# 1. Übersetzung ins Deutsche
#    "ctx" ist der vorangegangene Gesprächskontext, den die App ebenfalls
#    mitliefert – ohne ihn sind Pronomen und Fachbegriffe nicht auflösbar.
# ---------------------------------------------------------------------------
TRANSLATION = [
    {
        "lang": "en",
        "ctx": "We are reviewing the migration plan for the customer portal.",
        "src": "So the rollout is scheduled for the third week of March, but we still need sign-off from legal before we touch production.",
        "ref": "Der Rollout ist also für die dritte Märzwoche geplant, aber wir brauchen noch die Freigabe der Rechtsabteilung, bevor wir die Produktivumgebung anfassen.",
    },
    {
        "lang": "en",
        "ctx": "Discussion about a failing nightly build.",
        "src": "It looks like the flaky test is caused by a race condition in the cache warm-up, not by the database itself.",
        "ref": "Es sieht so aus, als würde der instabile Test durch eine Race Condition beim Aufwärmen des Caches verursacht, nicht durch die Datenbank selbst.",
    },
    {
        "lang": "en",
        "ctx": "Sales call with a prospect.",
        "src": "Honestly, the price point is a bit steep for us, but if you can include onboarding we could make a case internally.",
        "ref": "Ehrlich gesagt ist der Preis für uns etwas hoch, aber wenn Sie das Onboarding einschließen können, könnten wir das intern begründen.",
    },
    {
        "lang": "en",
        "ctx": "Standup meeting.",
        "src": "I'll take the ticket, but I'm blocked until someone gives me access to the staging cluster.",
        "ref": "Ich übernehme das Ticket, bin aber blockiert, bis mir jemand Zugriff auf das Staging-Cluster gibt.",
    },
    {
        "lang": "fr",
        "ctx": "Réunion de projet sur un retard de livraison.",
        "src": "Le fournisseur nous a confirmé que les pièces arriveront avec deux semaines de retard, donc il faut décaler la recette.",
        "ref": "Der Lieferant hat uns bestätigt, dass die Teile mit zwei Wochen Verspätung ankommen, also müssen wir die Abnahme verschieben.",
    },
    {
        "lang": "fr",
        "ctx": "Discussion budgétaire.",
        "src": "On peut absorber le surcoût cette année, mais pas si on garde le même périmètre l'an prochain.",
        "ref": "Wir können die Mehrkosten dieses Jahr auffangen, aber nicht, wenn wir nächstes Jahr denselben Umfang beibehalten.",
    },
    {
        "lang": "es",
        "ctx": "Reunión sobre un incidente en producción.",
        "src": "El servicio estuvo caído unos cuarenta minutos y todavía no sabemos si se perdieron pedidos.",
        "ref": "Der Dienst war etwa vierzig Minuten ausgefallen, und wir wissen noch nicht, ob Bestellungen verloren gegangen sind.",
    },
    {
        "lang": "es",
        "ctx": "Negociación de contrato.",
        "src": "Necesitamos que el plazo de preaviso sea de tres meses, no de seis, o no podremos firmar.",
        "ref": "Wir brauchen eine Kündigungsfrist von drei Monaten, nicht von sechs, sonst können wir nicht unterschreiben.",
    },
    {
        "lang": "it",
        "ctx": "Call tecnica con il partner.",
        "src": "Abbiamo già aggiornato la libreria, però il problema si presenta solo sotto carico elevato.",
        "ref": "Wir haben die Bibliothek bereits aktualisiert, das Problem tritt aber nur unter hoher Last auf.",
    },
    {
        "lang": "nl",
        "ctx": "Overleg over de planning.",
        "src": "Als we de deadline halen, moeten we wel accepteren dat de tests pas achteraf gebeuren.",
        "ref": "Wenn wir die Frist einhalten, müssen wir allerdings akzeptieren, dass die Tests erst im Nachhinein stattfinden.",
    },
    {
        "lang": "en",
        "ctx": "A colleague explains an architecture decision.",
        "src": "We went with event sourcing mainly because the audit requirements made it painful to do anything else.",
        "ref": "Wir haben uns hauptsächlich für Event Sourcing entschieden, weil die Audit-Anforderungen alles andere mühsam gemacht hätten.",
    },
    {
        "lang": "en",
        "ctx": "Customer support escalation.",
        "src": "The customer is not asking for a refund, they just want a realistic date they can communicate to their board.",
        "ref": "Der Kunde verlangt keine Rückerstattung, er möchte nur ein realistisches Datum, das er seinem Vorstand mitteilen kann.",
    },
]

# ---------------------------------------------------------------------------
# 2. Frageerkennung + Auflösung auf eine eigenständige Frage
#    label: True  -> es wurde eine Frage/Bitte an den Nutzer gestellt
#           False -> reine Aussage, keine Antwort nötig
# ---------------------------------------------------------------------------
QUESTIONS = [
    {
        "ctx": "A: We deployed the new indexer last night.",
        "utt": "How long does a full reindex take on the production dataset?",
        "label": True,
    },
    {
        "ctx": "A: The invoice service now retries three times.",
        "utt": "And what happens if all three retries fail?",
        "label": True,
    },
    {
        "ctx": "A: I looked at the memory graphs this morning.",
        "utt": "Memory has been flat at around four gigabytes since Tuesday.",
        "label": False,
    },
    {
        "ctx": "A: We need to decide on the auth provider.",
        "utt": "Can you walk us through why you would pick Keycloak over Auth0?",
        "label": True,
    },
    {
        "ctx": "A: The migration script is ready.",
        "utt": "I'll run it on staging tonight and report back tomorrow.",
        "label": False,
    },
    {
        "ctx": "B: We were talking about the caching layer.",
        "utt": "Sorry, could you repeat the last part? You broke up.",
        "label": True,
    },
    {
        "ctx": "A: Our error budget for the quarter is almost gone.",
        "utt": "So realistically, what would it take to get availability back to three nines?",
        "label": True,
    },
    {
        "ctx": "A: Everyone has reviewed the document.",
        "utt": "Great, then let's move on to the next agenda item.",
        "label": False,
    },
    {
        "ctx": "A: You mentioned you had experience with Kafka.",
        "utt": "Tell me about a time you had to debug consumer lag in production.",
        "label": True,
    },
    {
        "ctx": "A: The report generator is written in Python.",
        "utt": "It takes about twelve seconds for a thousand rows.",
        "label": False,
    },
    {
        "ctx": "A: We are comparing two storage options.",
        "utt": "Which one would you recommend if write throughput matters more than cost?",
        "label": True,
    },
    {
        "ctx": "A: I've added the metrics dashboard.",
        "utt": "The link is in the channel, feel free to look at it later.",
        "label": False,
    },
    {
        "ctx": "A: Let's talk about the incident from Friday.",
        "utt": "What was the actual root cause in the end?",
        "label": True,
    },
    {
        "ctx": "A: The API returns a 429 when clients go over the limit.",
        "utt": "Right, that matches what we documented last month.",
        "label": False,
    },
    {
        "ctx": "A: We're evaluating whether to self-host the model.",
        "utt": "Do you think a 14 billion parameter model is enough for our use case?",
        "label": True,
    },
    {
        "ctx": "A: I ran the benchmark twice.",
        "utt": "Both runs gave nearly identical numbers, so I trust the result.",
        "label": False,
    },
]

# ---------------------------------------------------------------------------
# 3. Kontextbezogene Antwortqualität
#    "must": Liste von Konzepten. Jedes Konzept ist eine Liste von Synonymen –
#    eines davon muss in der Antwort vorkommen.
# ---------------------------------------------------------------------------
ANSWERS = [
    {
        "ctx": "Es geht um eine öffentliche REST-API, die von vielen Clients genutzt wird.",
        "q": "Welchen HTTP-Statuscode sollten wir zurückgeben, wenn ein Client sein Rate-Limit überschreitet, und was gehört in die Antwort?",
        "must": [["429"], ["retry-after", "retry after"], ["header", "kopfzeile"]],
    },
    {
        "ctx": "Wir betreiben PostgreSQL und sehen seit dem letzten Release langsame Abfragen.",
        "q": "Wie würdest du vorgehen, um herauszufinden, welche Abfrage die Datenbank ausbremst?",
        "must": [
            ["pg_stat_statements", "pg stat statements", "statistik"],
            ["explain", "ausführungsplan", "query plan"],
            ["index"],
        ],
    },
    {
        "ctx": "Ein Kollege fragt nach dem Unterschied zweier Konzepte im Team-Onboarding.",
        "q": "Was ist der Unterschied zwischen Authentifizierung und Autorisierung?",
        "must": [
            ["identität", "wer", "identity"],
            ["berechtigung", "rechte", "darf", "zugriff"],
        ],
    },
    {
        "ctx": "Wir planen ein Deployment mit Kubernetes für einen zustandslosen Dienst.",
        "q": "Wann würdest du ein Deployment und wann ein StatefulSet nehmen?",
        "must": [
            ["zustandslos", "stateless", "zustandslose"],
            ["zustandsbehaftet", "stateful", "persistent", "identität"],
            ["volume", "speicher", "pvc"],
        ],
    },
    {
        "ctx": "Diskussion über Datenschutz in einer Kundenanwendung mit Sitz in der EU.",
        "q": "Was bedeutet Datenminimierung nach DSGVO konkret für unser Nutzerprofil?",
        "must": [
            ["erforderlich", "notwendig", "zweck"],
            ["nur", "beschränk", "minimal"],
        ],
    },
    {
        "ctx": "Wir haben eine Node.js-Anwendung, die unter Last hängen bleibt.",
        "q": "Woran kann es liegen, dass der Event Loop blockiert wird, und wie messen wir das?",
        "must": [
            ["synchron", "blocking", "blockierend", "cpu"],
            ["event loop", "eventloop", "lag", "latenz"],
        ],
    },
    {
        "ctx": "Der Kunde fragt im Vertriebsgespräch nach dem Betriebsmodell.",
        "q": "Welche Vorteile hat ein lokal betriebenes Sprachmodell gegenüber einer Cloud-API?",
        "must": [
            ["datenschutz", "vertraulich", "daten bleiben", "dsgvo"],
            ["kosten", "unabhängig", "offline", "internet"],
        ],
    },
    {
        "ctx": "Technische Klärung im Architekturmeeting über asynchrone Verarbeitung.",
        "q": "Warum brauchen wir bei einer Message Queue Idempotenz auf der Konsumentenseite?",
        "must": [
            ["mehrfach", "doppelt", "erneut", "at-least-once", "wiederholt"],
            ["zustellung", "verarbeit", "nachricht"],
        ],
    },
]
