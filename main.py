nom = input("Quel est le nom de ton personnage ?: ")
Classe = input("Quelle est la classe de ton personnage ? (ex: Guerrier, Mage, Voleur): ")
niveau = 1
niveau = input("Quel est le niveau de ton personnage ? (1-100): ")
points_de_vie = input("Combien de points de vie a ton personnage ? (1-100): ")
force = input("Quel est la force de ton personnage ? (1-100): ")

print(f"Ton personnage {nom} est un {Classe} de niveau {niveau} avec {points_de_vie} PV de vie et un niveau de force de {force}.")