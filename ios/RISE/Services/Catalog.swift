import Foundation

/// Reference data, mirroring the web app's TALENTS and LOC_GROUPS. Kept as a
/// Swift literal rather than fetched so the app is fully usable with no signal
/// — a student on a school bus can complete the whole questionnaire offline and
/// only needs a connection for live matching.
enum Catalog {

    static let talents: [Talent] = [
        Talent(id: "music", label: "Music & Performance",
               blurb: "Instruments, vocals, DJing, production", symbol: "music.note",
               capabilities: [
                Capability(id: "m1", text: "Guitar, ukulele or piano: I can accompany singalongs and lead informal group sessions."),
                Capability(id: "m2", text: "Vocals: I can lead group singing, hold a part in a choir, or perform for an audience."),
                Capability(id: "m3", text: "Concert instrument at intermediate or advanced level: I can perform recitals and teach fundamentals."),
                Capability(id: "m4", text: "Audio or DJ: I can run sound at a small event or make a playlist that fits a room.")
               ]),
        Talent(id: "education", label: "Education & Tutoring",
               blurb: "STEM, literacy, mentorship", symbol: "book",
               capabilities: [
                Capability(id: "e1", text: "Math and sciences: I can tutor core curriculum subjects up to my own grade level."),
                Capability(id: "e2", text: "Literacy and language: I can support reading, writing, and English language learners."),
                Capability(id: "e3", text: "Homework support: I can keep a group of younger kids on task and explain things patiently."),
                Capability(id: "e4", text: "Coding and digital skills: I can teach basic programming or help someone use a computer.")
               ]),
        Talent(id: "athletics", label: "Athletics & Sports",
               blurb: "Coaching, fitness, adaptive sports", symbol: "figure.run",
               capabilities: [
                Capability(id: "a1", text: "Team sport at competitive level: I can assist a coach and run drills for younger players."),
                Capability(id: "a2", text: "Refereeing or officiating: I know the rules well enough to officiate youth games."),
                Capability(id: "a3", text: "Adaptive and inclusive sport: I am comfortable supporting athletes with disabilities."),
                Capability(id: "a4", text: "Fitness and swimming: I can lead warm-ups or support a learn-to-swim programme.")
               ]),
        Talent(id: "environment", label: "Environment & Climate",
               blurb: "Conservation, outdoors, sustainability", symbol: "leaf",
               capabilities: [
                Capability(id: "n1", text: "Outdoor stewardship: I can plant, weed, clear invasive species and do trail work."),
                Capability(id: "n2", text: "Waste and recycling: I can run a sorting station or an audit at an event."),
                Capability(id: "n3", text: "Citizen science: I can record observations carefully and follow a data protocol."),
                Capability(id: "n4", text: "Animal care: I am comfortable handling and caring for animals under supervision.")
               ]),
        Talent(id: "business", label: "Business & Finance",
               blurb: "Entrepreneurship, financial literacy", symbol: "chart.line.uptrend.xyaxis",
               capabilities: [
                Capability(id: "b1", text: "Bookkeeping basics: I can keep simple records and reconcile a small float."),
                Capability(id: "b2", text: "Fundraising and events: I can plan and run a small fundraiser end to end."),
                Capability(id: "b3", text: "Social media and design: I can make posts and simple graphics that look right."),
                Capability(id: "b4", text: "Financial literacy: I can explain budgeting and saving to someone my age or younger.")
               ]),
        Talent(id: "community", label: "Community & Tech",
               blurb: "Digital skills, food banks, social care", symbol: "person.2",
               capabilities: [
                Capability(id: "c1", text: "Tech help: I can patiently teach an older adult to use a phone, tablet or computer."),
                Capability(id: "c2", text: "Food security: I can sort, pack and hand out food at a bank or community kitchen."),
                Capability(id: "c3", text: "Companionship: I can hold a real conversation with someone who is lonely."),
                Capability(id: "c4", text: "Translation: I can interpret between English and another language I speak well.")
               ])
    ]

    static let locations: [RLocation] = [
        // Ontario
        RLocation(id: "toronto", label: "Toronto — Downtown & Central", short: "Toronto", province: "Ontario"),
        RLocation(id: "scarborough", label: "Toronto — Scarborough / East York", short: "Scarborough", province: "Ontario"),
        RLocation(id: "north-york", label: "Toronto — North York / Etobicoke", short: "North York", province: "Ontario"),
        RLocation(id: "mississauga", label: "Mississauga", short: "Mississauga", province: "Ontario"),
        RLocation(id: "brampton", label: "Brampton", short: "Brampton", province: "Ontario"),
        RLocation(id: "york-region", label: "Vaughan / Markham / Richmond Hill", short: "York Region", province: "Ontario"),
        RLocation(id: "hamilton", label: "Hamilton", short: "Hamilton", province: "Ontario"),
        RLocation(id: "oakville", label: "Oakville", short: "Oakville", province: "Ontario"),
        RLocation(id: "burlington", label: "Burlington", short: "Burlington", province: "Ontario"),
        RLocation(id: "kitchener", label: "Kitchener / Waterloo", short: "Kitchener", province: "Ontario"),
        RLocation(id: "guelph", label: "Guelph", short: "Guelph", province: "Ontario"),
        RLocation(id: "ottawa", label: "Ottawa", short: "Ottawa", province: "Ontario"),
        RLocation(id: "london-on", label: "London, Ontario", short: "London", province: "Ontario"),
        RLocation(id: "kingston", label: "Kingston", short: "Kingston", province: "Ontario"),
        RLocation(id: "windsor", label: "Windsor / Essex County", short: "Windsor", province: "Ontario"),
        RLocation(id: "barrie", label: "Barrie / Simcoe County", short: "Barrie", province: "Ontario"),
        RLocation(id: "sudbury", label: "Greater Sudbury", short: "Sudbury", province: "Ontario"),
        RLocation(id: "thunder-bay", label: "Thunder Bay", short: "Thunder Bay", province: "Ontario"),
        RLocation(id: "oshawa", label: "Oshawa / Durham Region", short: "Oshawa", province: "Ontario"),
        RLocation(id: "niagara", label: "St. Catharines / Niagara", short: "Niagara", province: "Ontario"),
        RLocation(id: "peterborough", label: "Peterborough / Kawartha Lakes", short: "Peterborough", province: "Ontario"),
        // British Columbia
        RLocation(id: "vancouver", label: "Vancouver / Metro Vancouver", short: "Vancouver", province: "British Columbia"),
        RLocation(id: "burnaby", label: "Burnaby / New Westminster", short: "Burnaby", province: "British Columbia"),
        RLocation(id: "richmond-bc", label: "Richmond / Delta", short: "Richmond", province: "British Columbia"),
        RLocation(id: "surrey", label: "Surrey / Langley", short: "Surrey", province: "British Columbia"),
        RLocation(id: "victoria", label: "Victoria / Greater Victoria", short: "Victoria", province: "British Columbia"),
        RLocation(id: "kelowna", label: "Kelowna / Okanagan", short: "Kelowna", province: "British Columbia"),
        RLocation(id: "nanaimo", label: "Nanaimo / Vancouver Island", short: "Nanaimo", province: "British Columbia"),
        // Alberta
        RLocation(id: "calgary", label: "Calgary", short: "Calgary", province: "Alberta"),
        RLocation(id: "edmonton", label: "Edmonton", short: "Edmonton", province: "Alberta"),
        RLocation(id: "red-deer", label: "Red Deer", short: "Red Deer", province: "Alberta"),
        RLocation(id: "lethbridge", label: "Lethbridge", short: "Lethbridge", province: "Alberta"),
        // Québec
        RLocation(id: "montreal", label: "Montréal / Greater Montréal", short: "Montréal", province: "Québec"),
        RLocation(id: "quebec-city", label: "Québec City", short: "Québec City", province: "Québec"),
        RLocation(id: "laval", label: "Laval", short: "Laval", province: "Québec"),
        RLocation(id: "gatineau", label: "Gatineau / Outaouais", short: "Gatineau", province: "Québec"),
        // Prairies & Atlantic
        RLocation(id: "winnipeg", label: "Winnipeg", short: "Winnipeg", province: "Manitoba"),
        RLocation(id: "saskatoon", label: "Saskatoon", short: "Saskatoon", province: "Saskatchewan"),
        RLocation(id: "regina", label: "Regina", short: "Regina", province: "Saskatchewan"),
        RLocation(id: "halifax", label: "Halifax / HRM", short: "Halifax", province: "Nova Scotia"),
        RLocation(id: "moncton", label: "Moncton", short: "Moncton", province: "New Brunswick"),
        RLocation(id: "saint-john", label: "Saint John", short: "Saint John", province: "New Brunswick"),
        RLocation(id: "fredericton", label: "Fredericton", short: "Fredericton", province: "New Brunswick"),
        RLocation(id: "pei", label: "Charlottetown / PEI", short: "Charlottetown", province: "Prince Edward Island"),
        RLocation(id: "st-johns", label: "St. John's / Newfoundland", short: "St. John's", province: "Newfoundland"),
        RLocation(id: "whitehorse", label: "Whitehorse / Yukon", short: "Whitehorse", province: "Territories"),
        RLocation(id: "yellowknife", label: "Yellowknife / NWT", short: "Yellowknife", province: "Territories"),
        // Remote
        RLocation(id: "virtual", label: "Virtual: anywhere in Canada", short: "Virtual", province: "Virtual / Remote")
    ]

    static var provinces: [String] {
        var seen = Set<String>()
        return locations.compactMap { seen.insert($0.province).inserted ? $0.province : nil }
    }

    static func locations(in province: String) -> [RLocation] {
        locations.filter { $0.province == province }
    }

    static func talent(_ id: String) -> Talent? { talents.first { $0.id == id } }
    static func location(_ id: String) -> RLocation? { locations.first { $0.id == id } }

    // MARK: - Questionnaire options

    static let availability = [
        ("light", "1–2 hours a week", "Light and sustainable"),
        ("steady", "3–5 hours a week", "Committed and consistent"),
        ("deep", "6+ hours a week", "Community is a real priority"),
        ("events", "Events only", "Burst commitment, high impact")
    ]

    static let settings = [
        ("group", "Group settings", "Teams, kids, energetic spaces"),
        ("oneone", "1-on-1 depth", "Individual connections and mentorship"),
        ("either", "Either works", "I'm not fussy about the format")
    ]

    static let showUp = [
        ("homunteer", "From home", "Remote work for a cause"),
        ("local", "In my community", "In person, close to where I live"),
        ("either", "Either is fine", "Whatever fits the role")
    ]

    static let serve = [
        ("children", "Children (under 12)"), ("teens", "Teens and peers"),
        ("seniors", "Seniors"), ("disability", "People with disabilities"),
        ("newcomers", "Newcomers and refugees"), ("lowincome", "Low-income families"),
        ("animals", "Animals and wildlife"), ("any", "Open to anyone")
    ]

    static let languages = ["English", "French", "Mandarin", "Cantonese", "Punjabi", "Hindi",
                            "Urdu", "Spanish", "Portuguese", "Arabic", "Tagalog", "Vietnamese",
                            "Farsi", "Russian", "Ukrainian", "Korean", "Japanese", "Tamil",
                            "Bengali", "Gujarati", "Polish", "Italian", "German", "Greek",
                            "Somali", "Swahili", "Amharic", "Turkish", "American Sign Language"]
}
