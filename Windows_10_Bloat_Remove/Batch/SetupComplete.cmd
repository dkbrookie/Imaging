@echo off

powershell.exe -ExecutionPolicy Bypass New-Item C:\PostOOBETest.txt -ItemType File

net user /add DKB Dubstep247!
net localgroup administrators DKB1 /add