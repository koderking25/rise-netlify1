import Foundation

/// Prompts, tuned for a phone.
///
/// The web prompts assume a wide card with room for a paragraph. On a 375pt
/// screen that paragraph is eight lines and nobody reads it, so every field
/// here has an explicit length budget and the model is told what the text is
/// competing with. Shorter output is also cheaper output.
///
/// The other change is that "first step" is now required to be a single
/// physical action a teenager can take with a thumb. "Get in touch with the
/// organization" is not a step; "Email Priya at volunteer@… and say which
/// Saturdays you're free" is.
enum Prompts {

    static let system = """
    You are a volunteer-placement advisor for high-school students aged 14-18 in Canada. \
    You know the charitable sector well and you are honest about the limits of what you know.

    Rules you never break:
    - You only name organizations you are confident exist and are active today in the region asked about.
    - You return a ROLE, never a category. If you cannot name the position and say what the student \
    would actually do in one session, you do not have a match yet.
    - You never invent a contact name, an email address, or a deadline. Omit rather than guess.
    - You are writing for a phone screen. Every field has a length limit and you keep to it.
    - You are writing for a fourteen-year-old. Plain words, no sector jargon, no corporate voice.
    """

    // MARK: - Schemas

    static let oppSchema: [String: Any] = [
        "type": "ARRAY",
        "items": [
            "type": "OBJECT",
            "properties": [
                "title": ["type": "STRING"], "org": ["type": "STRING"],
                "role": ["type": "STRING"], "whyMatch": ["type": "STRING"],
                "commitment": ["type": "STRING"], "firstStep": ["type": "STRING"],
                "requirements": ["type": "STRING"], "where": ["type": "STRING"],
                "hours": ["type": "STRING"], "link": ["type": "STRING"],
                "contactEmail": ["type": "STRING"], "sourceUrl": ["type": "STRING"],
                "remote": ["type": "BOOLEAN"],
                "tags": ["type": "ARRAY", "items": ["type": "STRING"]]
            ],
            "required": ["title", "org", "role", "commitment", "firstStep", "where", "hours", "link", "remote"]
        ]
    ]

    static let judgeSchema: [String: Any] = [
        "type": "ARRAY",
        "items": [
            "type": "OBJECT",
            "properties": [
                "id": ["type": "INTEGER"], "capability": ["type": "INTEGER"],
                "population": ["type": "INTEGER"], "logistics": ["type": "INTEGER"],
                "credibility": ["type": "INTEGER"], "total": ["type": "INTEGER"],
                "evidence": ["type": "STRING"], "verdict": ["type": "STRING"]
            ],
            "required": ["id", "capability", "population", "logistics", "credibility", "total", "evidence", "verdict"]
        ]
    ]

    // MARK: - Angles

    /// Four search strategies, phrased for a category-and-place question rather
    /// than a specific student — this prompt deliberately contains no student.
    static let angles = [
        "START HERE: search the category as a role title plus the place. Favour the smallest, most specific organizations that come back — one neighbourhood house or a single hospital programme beats a national charity's generic page.",
        "START HERE: search the local volunteer-matching boards and the city's own volunteer portal for currently-listed postings in this category. Open the individual listings, not the category pages.",
        "START HERE: think about which institutions structurally need this category of help — hospitals, long-term care homes, libraries, school boards, settlement agencies, community centres, animal shelters — then search those named institution types in this place.",
        "START HERE: search for the populations this category most often serves in this place — seniors, newcomers, children, people with disabilities — find the organizations serving them, then check each volunteer page for roles in this category."
    ]

    // MARK: - Discovery (shared, impersonal)

    static func discovery(talent: Talent, location: RLocation, angle: Int, remoteOnly: Bool) -> String {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return """
        Find 10 SPECIFIC volunteer ROLES a 14-18 year old could apply to. Search the live web, open the \
        actual listings, then call emit once.

        TODAY IS \(today). Look for positions open THIS WEEK. Prefer a dated, currently-open posting over an \
        evergreen "we sometimes need volunteers" page. If a listing shows a posting date, deadline, term start \
        or intake session, put it in "commitment".

        \(angles[angle % angles.count])

        WHERE
        - \(remoteOnly ? "REMOTE ONLY — the role must be doable entirely from home." : "\(location.label), Canada")
        - Category: \(talent.label)

        WHERE ELSE TO LOOK — pages carrying real postings, not advice:
          · the local volunteer centre and its listings board
          · \(remoteOnly ? "remote and virtual volunteering boards" : "\"\(location.short) volunteer\" listing sites")
          · named organizations' own Volunteer / Get Involved pages

        RANGE MATTERS. A careful advisor narrows this list down afterwards, so return roles that differ from \
        each other — different organizations, populations, time commitments, skills. Ten near-identical \
        tutoring roles are worth less than six genuinely different ones.

        WRITING FOR A PHONE — keep to these limits or the text is cut off on screen:
        - "role": what they'd actually do in one session. One sentence, max 20 words. Concrete verbs.
        - "commitment": max 8 words, e.g. "2 hrs/week, Saturdays, term starts Sept 15".
        - "firstStep": ONE action the student takes with their thumb, max 15 words. Name who to contact if \
        the posting names them. "Get in touch" is not a step.
        - "requirements": only real barriers — police check, minimum age, training session. Max 12 words. \
        Omit if none.

        Set "remote" true ONLY if the whole role is doable from home with no in-person attendance. Hybrid \
        is false.

        Set "sourceUrl" to the exact page you read it on, and "link" to the organization's root homepage. \
        If a posting names a coordinator or an email, put them in firstStep and contactEmail. Never invent one.

        Return fewer than 10 rather than padding with roles any volunteer could do.
        """
    }

    // MARK: - Judge (personal)

    static func judge(pool: [Opportunity], profile: StudentProfile,
                      talent: Talent, location: RLocation) -> String {
        let list = pool.enumerated().map { i, o in
            """
            [\(i)] \(o.title) — \(o.org)
                does: \(o.role ?? o.whyMatch ?? "unstated")
                commitment: \(o.commitment ?? "unstated") | where: \(o.whereText ?? "unstated") | needs: \(o.requirements ?? "none listed")
            """
        }.joined(separator: "\n")

        let caps = profile.capabilities.isEmpty ? "none given" : profile.capabilities.joined(separator: "; ")
        let serve = profile.serve.isEmpty ? "No population stated — any is acceptable" : profile.serve.joined(separator: ", ")

        return """
        Score how well each candidate volunteer role fits this specific student. You did not write these \
        candidates and you have no stake in them — reject the weak ones.

        STUDENT
        - Location: \(location.label), Canada
        - Interest areas: \(talent.label)
        - What they say they can do: "\(caps)"
        \(profile.languages.isEmpty ? "" : "- Languages: \(profile.languages.joined(separator: ", "))")
        \(profile.detail.isEmpty ? "" : "- In their own words (HIGHEST PRIORITY — match this closely): \"\(profile.detail)\"")
        - Wants to serve: \(serve)
        - Availability: \(profile.availability.isEmpty ? "flexible" : profile.availability)
        - Setting: \(profile.setting.isEmpty ? "any" : profile.setting)\(profile.virtualOnly ? " (REMOTE ONLY — anything in-person scores 0 on logistics)" : "")

        CANDIDATES
        \(list)

        Score each out of these maximums and put the sum in "total":
        - capability  /40  Does the role NEED what this student can do? A role any willing person could fill \
        scores low however pleasant it is. This is the dimension that matters most.
        - population  /20  Does it serve who they wanted to serve?
        - logistics   /20  Does the commitment fit their stated availability and setting?
        - credibility /20  How confident are you this organization and role are real and currently active?

        "evidence" must name the SPECIFIC DUTY in this role that needs this student's stated capability, and \
        it must be ONE sentence of at most 22 words, written to the student as "you". If you cannot name such \
        a duty, say so plainly and score capability below 15.

        "verdict" is "strong", "good", or "reject". Reject anything you would be embarrassed to put in front \
        of this student — a category rather than a role, an organization you are unsure exists, or a role \
        their stated capability has nothing to do with. Rejecting is expected; a list of four honest matches \
        beats ten padded ones.
        """
    }

    // MARK: - Outreach

    static func outreach(opp: Opportunity, profile: StudentProfile) -> String {
        """
        Write the first email from this student to this organization.

        STUDENT: \(profile.name.isEmpty ? "a high-school student" : profile.name), aged 14-18
        THEY CAN: \(profile.capabilities.joined(separator: "; "))
        \(profile.detail.isEmpty ? "" : "IN THEIR WORDS: \"\(profile.detail)\"")
        ROLE: \(opp.title) at \(opp.org)
        WHAT IT INVOLVES: \(opp.role ?? "")

        Rules:
        - Six sentences maximum. It is read on a phone by a busy coordinator.
        - Open with what they can do and why this role specifically, not "I am writing to express interest".
        - Name one concrete thing they'd contribute in a session.
        - Ask one clear question — usually whether the role is still open and what the next step is.
        - No em-dashes. No "passionate". No "I believe my skills align".
        - Sign off with the student's first name only.
        - Return the email body only. No subject line, no preamble, no notes.
        """
    }
}
