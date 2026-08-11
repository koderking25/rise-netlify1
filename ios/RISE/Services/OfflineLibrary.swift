import Foundation

/// The guaranteed engine — real Canadian organizations with national reach that
/// welcome youth volunteers.
///
/// This exists so the app is never empty and never lies. With no signal, a dead
/// proxy, or the daily spend cap reached, the student still gets real
/// organizations they can actually contact, clearly labelled as starting points
/// rather than passed off as tailored live matches.
enum OfflineLibrary {

    private static let entries: [String: [Opportunity]] = [
        "music": [
            make("Music Visits Volunteer", "Alzheimer Society of Canada",
                 role: "Play or share music with people living with dementia in a local programme.",
                 hours: "1–2 hrs/week", link: "https://alzheimer.ca"),
            make("Recreation & Music Volunteer", "YMCA Canada",
                 role: "Lead singalongs and mini performances in youth and senior rec programmes.",
                 hours: "2 hrs/week", link: "https://ymca.ca"),
            make("Long-Term Care Entertainer", "AdvantAge Ontario",
                 role: "Perform short sets for residents in long-term care homes.",
                 hours: "1 hr/visit", link: "https://advantageontario.ca")
        ],
        "education": [
            make("Homework Club Volunteer", "Your local public library",
                 role: "Help younger students with homework and reading at a drop-in club.",
                 hours: "1–2 hrs/week", link: "https://canada.ca"),
            make("Youth Tutor", "Boys and Girls Clubs of Canada",
                 role: "Tutor core subjects in an after-school programme.",
                 hours: "2 hrs/week", link: "https://bgccan.com"),
            make("Newcomer Homework Helper", "YMCA Newcomer Services",
                 role: "Support newcomer students with schoolwork and English practice.",
                 hours: "2 hrs/week", link: "https://ymca.ca"),
            make("Reading Buddy", "Frontier College",
                 role: "Read with a child weekly to build their confidence and fluency.",
                 hours: "1–2 hrs/week", link: "https://frontiercollege.ca")
        ],
        "athletics": [
            make("Assistant Coach", "Special Olympics Canada",
                 role: "Run drills and support athletes with intellectual disabilities at practice.",
                 hours: "2 hrs/week", link: "https://specialolympics.ca"),
            make("Youth Sport Volunteer", "Canadian Tire Jumpstart",
                 role: "Help run community sport sessions for kids who face barriers.",
                 hours: "2–3 hrs/week", link: "https://jumpstart.canadiantire.ca"),
            make("Programme Helper", "KidSport Canada",
                 role: "Support local sport programmes and equipment drives.",
                 hours: "Flexible", link: "https://kidsportcanada.ca")
        ],
        "environment": [
            make("Stewardship Volunteer", "Nature Conservancy of Canada",
                 role: "Plant native species, clear invasives and maintain trails on protected land.",
                 hours: "Half-day events", link: "https://natureconservancy.ca"),
            make("Shoreline Cleanup Leader", "Great Canadian Shoreline Cleanup",
                 role: "Organise or join a local shoreline cleanup and record what you find.",
                 hours: "2–3 hrs/event", link: "https://shorelinecleanup.ca"),
            make("Animal Care Assistant", "Your local SPCA or humane society",
                 role: "Socialise, walk and care for shelter animals under staff supervision.",
                 hours: "2–4 hrs/week", link: "https://spca.ca")
        ],
        "business": [
            make("Fundraising Volunteer", "United Way Centraide Canada",
                 role: "Help plan and run a local campaign event end to end.",
                 hours: "Campaign season", link: "https://unitedway.ca"),
            make("Financial Literacy Peer Leader", "Junior Achievement Canada",
                 role: "Deliver money-skills sessions to students your own age or younger.",
                 hours: "Programme blocks", link: "https://jacanada.org"),
            make("Social Media Helper", "Volunteer Canada",
                 role: "Make posts and simple graphics for a small charity's channels.",
                 hours: "1–2 hrs/week", link: "https://volunteer.ca")
        ],
        "community": [
            make("Food Bank Sorter", "Food Banks Canada",
                 role: "Sort, pack and organise donations at your community food bank.",
                 hours: "2–4 hrs/week", link: "https://foodbankscanada.ca"),
            make("Buddy Programme Volunteer", "Best Buddies Canada",
                 role: "Build a one-to-one friendship with a peer who has a disability.",
                 hours: "1 hr/week", link: "https://bestbuddies.ca"),
            make("Community Kitchen Helper", "Community Food Centres Canada",
                 role: "Help run meal programmes, gardens and food-skills classes.",
                 hours: "2–3 hrs/week", link: "https://communityfoodcentres.ca"),
            make("Tech Help Volunteer", "Canadian Red Cross",
                 role: "Teach an older adult to use a phone or tablet, patiently.",
                 hours: "1–3 hrs/week", link: "https://redcross.ca")
        ]
    ]

    private static func make(_ title: String, _ org: String, role: String,
                             hours: String, link: String) -> Opportunity {
        var o = Opportunity(title: title, org: org)
        o.role = role
        o.hours = hours
        o.commitment = hours
        o.link = link
        o.firstStep = "Open their volunteer page and use the contact form."
        o.remote = false
        o.curated = true
        o.origin = "library"
        o.tags = ["youth-friendly", "national"]
        return o
    }

    static func candidates(talent: Talent, location: RLocation, remoteOnly: Bool) -> [Opportunity] {
        var list = entries[talent.id] ?? []
        // Backfill from community so a thin category still fills a screen.
        if list.count < 4, talent.id != "community" {
            list += (entries["community"] ?? []).prefix(4 - list.count)
        }
        return list.map { o in
            var o = o
            o.whereText = remoteOnly ? "Remote where offered" : "\(location.short): local branch or chapter"
            return o
        }
    }

    /// Transparent keyword scoring. Noisy, but it never hallucinates and it
    /// works with no network — which is what makes it a safe floor under the
    /// model's judgement rather than a replacement for it.
    static func deterministicScore(_ o: Opportunity, profile: StudentProfile) -> Int {
        var score = 45
        let hay = "\(o.title) \(o.role ?? "") \(o.org)".lowercased()

        // Capability overlap is the dimension that matters most, so it carries
        // the most weight here too.
        let words = profile.capabilities
            .flatMap { $0.lowercased().split(separator: " ") }
            .filter { $0.count > 4 }
        let hits = Set(words).filter { hay.contains($0) }.count
        score += min(hits * 6, 30)

        // Serving the population they asked for.
        for s in profile.serve where hay.contains(s.lowercased()) { score += 6 }

        // Respecting the format they can actually do.
        if profile.virtualOnly && o.isRemote { score += 10 }
        if profile.virtualOnly && !o.isRemote { score -= 25 }

        // A role you can act on today beats one you cannot.
        if o.isActionable { score += 4 }

        return max(5, min(96, score))
    }
}
