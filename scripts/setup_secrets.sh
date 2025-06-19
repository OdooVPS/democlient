#!/bin/bash
# --------------------------------------------------------------------
# Script para cargar todos los secretos necesarios para el despliegue
# de Odoo en un repositorio de GitHub usando la CLI 'gh'.
#
# Uso:
# 1. Asegúrate de estar en el directorio de tu repositorio local.
# 2. Ejecuta ./setup_secrets.sh
# --------------------------------------------------------------------

set -e # Detiene el script si algún comando falla

echo "--- Iniciando la carga de secretos de GitHub Actions ---"

# --- Secreto 1: Clave SSH del Servidor ---
# El mejor método: leer desde el archivo.
echo "Cargando ODOO_SERVER_SSH_KEY..."
gh secret set ODOO_SERVER_SSH_KEY < ~/.ssh/ssh-fdg-2022

# --- Secretos de Conexión y Autenticación ---
# Usamos --body para valores simples.
echo "Cargando secretos del servidor y Docker..."
gh secret set ODOO_SERVER_IP --body "142.93.226.4"
gh secret set ODOO_SERVER_USER --body "root"
gh secret set DOCKERHUB_USERNAME --body "fdelanuez"

# --- Secretos de la Base de Datos ---
echo "Cargando secretos de la base de datos..."
gh secret set DB_HOST --body "private-db-postgresql-ams3-09944-do-user-4957761-0.j.db.ondigitalocean.com"
gh secret set DB_PORT --body "25060"
gh secret set DB_SUPERUSER --body "doadmin"

# --- Secretos Sensibles: Contraseñas y Tokens ---
# Para estos, el método interactivo es el más seguro si no los quieres en un script.
# Pero para automatización completa, puedes cargarlos desde un archivo local
# que esté en tu .gitignore para que nunca se suba al repositorio.

echo "Ahora se pedirán los secretos más sensibles de forma interactiva."
echo "Puedes pegar los valores y presionar Enter."

gh secret set DOCKERHUB_TOKEN
gh secret set DB_SUPERUSER_PASS
gh secret set GENERIC_ODOO_ADMIN_PASS
gh secret set GENERIC_DB_CLIENT_PASS


echo "✅ ¡Todos los secretos han sido cargados exitosamente!"

# --- Comandos útiles adicionales ---
echo "Verificando la lista de secretos creados (sin sus valores)..."
gh secret list
