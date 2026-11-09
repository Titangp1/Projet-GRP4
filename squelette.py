import random
from random import randint

squelette_point_de_vie = 10
joueur_attack = random.randint(5, 15)
niveau_joueur = 1

if joueur_attack >= 10:
    print("Le squelette est mort !")
    niveau_joueur += 1
else:
    print("Le squelette se moque de toi...")