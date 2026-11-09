import random

golem_point_de_vie = 50
point_de_vie_joueur = 100

while golem_point_de_vie > 0:
    print("\n--- Nouveau tour ---")
    print("1: Coup d'épée (10 à 14 dégâts)")
    print("2: Lancer de dague (2 à 22 dégâts)")
    print("3: Boule de feu (0 ou 20 dégâts)")
    
    choix = input("Quel sort voulez-vous lancer ? (1, 2 ou 3) : ")
    
    if choix == "1":
        nom_sort = "Coup d'épée"
        degats = random.randint(10, 14)
    elif choix == "2":
        nom_sort = "Lancer de dague"
        degats = random.randint(2, 22)
    elif choix == "3":
        nom_sort = "Boule de feu"
        degats = random.choice([0, 20])
    else:
        print("Choix invalide, vous manquez votre tour !")
        nom_sort = "Aucun"
        degats = 0

    print(f"Vous avez choisi le sort {nom_sort} !")
    
    golem_point_de_vie -= degats
    
    point_de_vie_joueur -= 7
    
    print(f"Le Golem a maintenant {golem_point_de_vie} PV et vous avez {point_de_vie_joueur} PV.")

print("\nLe Golem est KO !")