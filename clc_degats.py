def calcul_degats(force, arme):
    arme = 50
    force = input("Quel est la puissance de votre arme ? (1-100): ")
    degats = force * arme / 100
    print ("Votre personnage inflige", degats, "points de dégâts avec son arme.")