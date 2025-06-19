#!/bin/bash
# Este script se ejecuta en el runner de GitHub Actions.
set -e

echo "--- Iniciando script de despliegue de Odoo ---"

# === PASO 1: PREPARACIÓN DE VARIABLES ===
# Usamos las variables de entorno inyectadas por el workflow de GitHub Actions.
export PROJECT_NAME="${INPUT_PROJECT_NAME}"
export PROJECT_NAME_LOWER=$(echo "${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]')
export PROJECT_FULL_NAME="${PROJECT_NAME_LOWER}_production"
export TRAEFIK_HOST="${PROJECT_NAME_LOWER}.${INPUT_DOMAIN_NAME}"

export DB_NAME="${PROJECT_FULL_NAME}"
export DB_USER="u_${PROJECT_FULL_NAME}"
# Creamos una contraseña única para la BD del cliente
export DB_PASSWORD="${GENERIC_DB_CLIENT_PASS}_${PROJECT_NAME_LOWER}"

# Exportamos el resto de variables para que 'envsubst' las pueda usar
export ODOO_VERSION="${INPUT_ODOO_VERSION}"
export ODOO_WEB_PORT="${INPUT_ODOO_WEB_PORT}"
export ODOO_LONGPOLLING_PORT="${INPUT_ODOO_LONGPOLLING_PORT}"
export ODOO_ADMIN_PASSWD="${GENERIC_ODOO_ADMIN_PASS}"
# Las variables de Docker, Servidor y BD ya están exportadas por GitHub Actions

echo "Variables preparadas para el proyecto: ${PROJECT_FULL_NAME}"
echo "Host de despliegue: https://${TRAEFIK_HOST}"

# === PASO 2: APROVISIONAMIENTO DE BASE DE DATOS (EJECUCIÓN REMOTA) ===
echo "Aprovisionando base de datos en ${DB_HOST}..."
# Las comillas simples en 'EOF' son cruciales. Evitan que las variables se expandan localmente.
# Se expandirán en el servidor remoto donde corre psql.
ssh -o StrictHostKeyChecking=no ${ODOO_SERVER_USER}@${ODOO_SERVER_IP} "PGPASSWORD=${DB_SUPERUSER_PASS} psql -h ${DB_HOST} -p ${DB_PORT} -U ${DB_SUPERUSER} -d postgres <<'EOF'
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
      CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
      ALTER USER ${DB_USER} CREATEDB;
   END IF;
END
\$\$;
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}') THEN
      CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
   END IF;
END
\$\$;
\c ${DB_NAME}
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOF
"
echo "Base de datos aprovisionada."


# === PASO 3: PREPARAR ARCHIVOS DE PROYECTO LOCALMENTE (EN EL RUNNER) ===
PROJECT_DIR_LOCAL="./${PROJECT_FULL_NAME}"
mkdir -p "${PROJECT_DIR_LOCAL}/config"
echo "Directorio de trabajo local creado: ${PROJECT_DIR_LOCAL}"

# Usamos 'envsubst' para reemplazar las variables en las plantillas. Es más limpio que 'sed'.
envsubst < ./templates/deploy.yml.template > "${PROJECT_DIR_LOCAL}/config/deploy.yml"
envsubst < ./templates/odoo.conf.template > "${PROJECT_DIR_LOCAL}/config/odoo.conf"

# Creamos el Dockerfile directamente
cat << EOF > "${PROJECT_DIR_LOCAL}/Dockerfile"
FROM odoo:${ODOO_VERSION}
COPY config/odoo.conf /etc/odoo/odoo.conf
RUN chown odoo:odoo /etc/odoo/odoo.conf
EOF

echo "Archivos de configuración para Kamal generados."


# === PASO 4: COPIAR ARCHIVOS AL SERVIDOR DE DESTINO ===
PROJECT_DIR_REMOTE="/opt/odoo_projects/${PROJECT_FULL_NAME}"
echo "Transfiriendo archivos a ${ODOO_SERVER_IP}:${PROJECT_DIR_REMOTE}"
ssh ${ODOO_SERVER_USER}@${ODOO_SERVER_IP} "mkdir -p ${PROJECT_DIR_REMOTE}/{config,data,private-addons,extra-addons,enterprise,backups}"
scp -r "${PROJECT_DIR_LOCAL}"/* ${ODOO_SERVER_USER}@${ODOO_SERVER_IP}:${PROJECT_DIR_REMOTE}/


# === PASO 5: EJECUTAR KAMAL REMOTAMENTE ===
echo "Ejecutando Kamal en el servidor de destino..."
# Aquí, las variables YA HAN SIDO expandidas porque no usamos comillas en el primer EOF.
ssh ${ODOO_SERVER_USER}@${ODOO_SERVER_IP} << EOF
  set -e
  cd ${PROJECT_DIR_REMOTE}

  # Creamos el .env para los secretos que necesita Kamal en el servidor
  echo "DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}" > .env
  echo "ODOO_ADMIN_PASSWD=${ODOO_ADMIN_PASSWD}" >> .env
  echo "DB_PASSWORD=${DB_PASSWORD}" >> .env

  # Ejecutar Kamal (asegúrate de que kamal está instalado en el servidor de destino)
  kamal setup
  kamal env push
  kamal deploy
EOF

echo "✅ ✅ ✅ ¡DESPLIEGUE COMPLETADO EXITOSAMENTE! ✅ ✅ ✅"
echo "Instancia disponible en: https://${TRAEFIK_HOST}"
