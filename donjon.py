import random

def exploration_donjon():
    print("=== DEBUT DE L'EXPLORATION DU DONJON ===")
    
    print("\n--- Salle 1 : Le Squelette ---")
    squelette_point_de_vie = 10
    joueur_attack = random.randint(5, 15)
    niveau_joueur = 1

    print(f"Vous attaquez le squelette avec une puissance de {joueur_attack} !")
    if joueur_attack >= squelette_point_de_vie:
        print("Le squelette est vaincu !")
        niveau_joueur += 1
    else:
        print("Le squelette se moque de toi... mais vous réussissez quand même à passer !")


    print("\n--- Salle 2 : La Porte Verrouillée ---")
    code_porte = random.randint(1, 10)
    tentative = None

    while tentative != code_porte:
        tentative = int(input("Entrez le code de la porte (entre 1 et 10) : "))
        if tentative < code_porte:
            print("Trop petit !")
        elif tentative > code_porte:
            print("Trop grand !")
        else:
            print("Clic ! La porte s'ouvre !")

    print("\n--- Salle 3 : Le Golem ---")
    golem_point_de_vie = 50
    point_de_vie_joueur = 100

    while golem_point_de_vie > 0 and point_de_vie_joueur > 0:
        print("\n--- Tour de combat ---")
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
        
        print(f"Le Golem a maintenant {max(0, golem_point_de_vie)} PV et vous avez {max(0, point_de_vie_joueur)} PV.")

    if point_de_vie_joueur > 0:
        print("\nLe Golem est KO !")

        print("\nFélicitations, tu as terminé le donjon !")
    else:
        print("\nVous avez été vaincu par le Golem...")

if __name__ == "__main__":
    exploration_donjon()