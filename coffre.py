import random

code_magique = random.randint(1, 20)
essais = 0
inventaire = ["Pièce d'Or"]

while essais < 3:
    choix_nombre = int(input("Choisis un nombre entre 1 et 20 : "))
    essais += 1

    if choix_nombre == code_magique:
        print("Bravo ! Vous avez trouvez l'Arme Ultime !")
        inventaire.append("l'Arme Ultime")
        break
    elif choix_nombre < code_magique:
        print("Trop bas")
    else:
        print("Trop haut")

# Si le joueur n'a pas trouvé au bout de 3 essais
if essais >= 3 and "l'Arme Ultime" not in inventaire:
    print("Le coffre a manger votre Or !")
    if "Pièce d'Or" in inventaire:
        inventaire.remove("Pièce d'Or")