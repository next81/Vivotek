# Vivotek Modul für FHEM

Wer einen Vivotek NVR besitzt kann über dieses Modul dort angeschlossene Kameras steuern. Derzeit unterstützt das Modul die Erkennung und Überwachung der Kameras und NVR sowie die Steuerung der Aufzeichnung (Ein/Aus/Automatik). Es lässt sich damit sehr praktisch die Videoüberwachung über FHEM steuern. Man kann das schön über das PRESENCE Modul kombinieren (z.b. Aufzeichnung starten wenn man das Haus verlässt und stoppen wenn man nach hause kommt). Auch kann man eine Manipulation der Kameras damit überwachen und mit der Alarmanlage verbinden etc. 

Die Einbindung ist denkbar einfach.

## Installation
Die Dateien 50_Vivotek.pm und 51_VivotekDevice.pm müssen in das Verzeichnis FHEM kopiert werden. Es werden zusätzlich die Module Crypt::OpenSSL und Crypt::OpenSSL::Bignum benötigt.

`apt-get install libcrypt-openssl-bignum-perl libcrypt-openssl-rsa-perl`

Der Rest sollte in jeder Standardinstallation bereits vorhanden sein.

## 2. Definition
Die Einbindung erfolgt denkbar einfach. Es muss hier lediglich die Adresse (DNS oder IP) des NVR angegeben werden.

`define <devicename> Vivotek <Adresse>`

Im Anschluss müssen die Logindaten hinterlegt werden. Das erfolgt über das Attribut "username" und das Setting "Password". Das Passwort wird leicht "verschlüsselt" im KeyValue Store von FHEM gespeichert.
Wenn die Logindaten richtig angegeben wurden braucht es im Anschluss zwei Durchläufe, bis das Modul alle angeschlossenen Kameras erkennt. Die Devices werden automatisch angelegt und können danach frei umbenannt werden.

Über das Attribut interval kann der Intervall der Abfragen in Sekunden bestimmt werden. Default sind 60 Sekunden, was völlig ausreichend sein sollte.

Getestet und lauffähig ist es auf dem ND9425P. Ältere Geräte dürften nicht funktionieren, da Vivotek vor einer Weile das gesamte System auf OpenSSL umgestellt hat.
