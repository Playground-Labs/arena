import Foundation

/// Fictional and mythological settings for human-created session defaults.
enum SessionNames {
    static let locations = [
        // Mythology and comics
        "Asgard", "Olympus", "Valhalla", "Elysium", "Tartarus", "Avalon", "Camelot", "Atlantis",
        "Metropolis", "Gotham", "Themyscira", "Wakanda", "Latveria", "Genosha", "Sokovia", "Krypton",
        "Smallville", "Central City", "Star City", "Coast City", "Gorilla City", "Kahndaq",
        // Middle-earth
        "The Shire", "Rivendell", "Lothlórien", "Gondor", "Rohan", "Mordor", "Isengard", "Moria",
        "Erebor", "Dale", "Bree", "Hobbiton", "Minas Tirith", "Minas Morgul", "Helm’s Deep", "Fangorn",
        // A Song of Ice and Fire
        "Westeros", "Essos", "Winterfell", "King’s Landing", "Dragonstone", "Braavos", "Pentos",
        "Volantis", "Qarth", "Meereen", "Astapor", "Yunkai", "Dorne", "Highgarden", "Casterly Rock",
        "The Eyrie", "Riverrun", "Harrenhal", "Oldtown", "Valyria",
        // Literature and animation
        "Narnia", "Cair Paravel", "Lantern Waste", "Calormen", "Archenland", "Wonderland", "Neverland",
        "Oz", "Emerald City", "Munchkinland", "Hogwarts", "Hogsmeade", "Diagon Alley", "Azkaban",
        "Beauxbatons", "Durmstrang", "Godric’s Hollow", "Whoville", "Hundred Acre Wood", "Arendelle",
        "Agrabah", "Atlantica", "Monstropolis", "Zootopia", "San Fransokyo", "Berk", "Far Far Away",
        // Science fiction
        "Tatooine", "Coruscant", "Naboo", "Alderaan", "Bespin", "Dagobah", "Mustafar", "Hoth",
        "Kashyyyk", "Kamino", "Geonosis", "Mandalore", "Jakku", "Scarif", "Jedha", "Exegol",
        "Arrakis", "Caladan", "Giedi Prime", "Kaitain", "Salusa Secundus", "Trantor", "Terminus",
        "Vulcan", "Romulus", "Qo’noS", "Bajor", "Cardassia",
        // Games, television, and horror
        "Hyrule", "Kakariko Village", "Gerudo Town", "Zora’s Domain", "Goron City", "Clock Town",
        "Termina", "Koholint Island", "Mushroom Kingdom", "Isle Delfino", "New Donk City", "Dream Land",
        "Midgar", "Nibelheim", "Cosmo Canyon", "Zanarkand", "Besaid", "Balamb Garden", "Alexandria",
        "Rapture", "Columbia", "Night City", "Novigrad", "Kaer Morhen", "Skellige", "Toussaint",
        "Whiterun", "Solitude", "Riften", "Windhelm", "Markarth", "Morrowind", "Cyrodiil",
        "Woodsboro", "Haddonfield", "Springwood", "Silent Hill", "Raccoon City", "Derry", "Castle Rock",
        "Hawkins", "Sunnydale", "Twin Peaks", "Stars Hollow", "Pawnee", "Schitt’s Creek", "Bikini Bottom"
    ]

    static func resolve(_ name: String, default defaultName: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }
}
