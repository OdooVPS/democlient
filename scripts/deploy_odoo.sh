#!/bin/bash
# Este script se ejecuta en el runner de GitHub Actions.
set -e

echo "--- Iniciando script de despliegue de Odoo ---"

# === PASO 1: PREPARACIÓN DE VARIABLES ===
export PROJECT_NAME="${INPUT_PROJECT_NAME}"
export PROJECT_NAME_LOWER=$(echo "${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]')
export PROJECT_FULL_NAME="${PROJECT_NAME_LOWER}_production"
export TRAEFIK_HOST="${PROJECT_NAME_LOWER}.${INPUT_DOMAIN_NAME}"
export DB_NAME="${PROJECT_FULL_NAME}"
export DB_USER="u_${PROJECT_FULL_NAME}"
export DB_PASSWORD="${GENERIC_DB_CLIENT_PASS}_${PROJECT_NAME_LOWER}"
export ODOO_VERSION="${INPUT_ODOO_VERSION}"
export ODOO_WEB_PORT="${INPUT_ODOO_WEB_PORT}"
export ODOO_LONGPOLLING_PORT="${INPUT_ODOO_LONGPOLLING_PORT}"
export ODOO_ADMIN_PASSWD="${GENERIC_ODOO_ADMIN_PASS}"
echo "Variables preparadas para el proyecto: ${PROJECT_FULL_NAME}"
echo "Host de despliegue: https://${TRAEFIK_HOST}"

# === PASO 2: APROVISIONAMIENTO DE BASE DE DATOS (EJECUCIÓN REMOTA) ===
echo "Aprovisionando base de datos en ${DB_HOST}..."
ssh -o StrictHostKeyChecking=no ${ODOO_SERVER_USER}@${ODOO_SERVER_IP} << EOF
  set -e
  export PGPASSWORD=${DB_SUPERUSER_PASS}
  psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_SUPERUSER}" -d "postgres" -c \
    "DO \\\$\\\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}'; ALTER USER ${DB_USER} CREATEDB; END IF; END \\\$\\\$;"
  echo "Comprobación/creación de usuario completada."
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_SUPERUSER}" -lqt | cut -d \| -f 1 | grep -qw "${DB_NAME}"; then
    echo "La base de datos ${DB_NAME} ya existe."
  else
    echo "La base de datos ${DB_NAME} no existe. Creando..."
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_SUPERUSER}" -d "postgres" -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"
  fi
  psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_SUPERUSER}" -d "${DB_NAME}" -c \
    "CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  echo "Comprobación/creación de extensiones completada."
EOF
echo "Aprovisionamiento de base de datos completado."


# === PASO 3: PREPARAR ARCHIVOS DE PROYECTO LOCALMENTE (EN EL RUNNER) ===
PROJECT_DIR_LOCAL="./${PROJECT_FULL_NAME}"
mkdir -p "${PROJECT_DIR_LOCAL}/config"
echo "Directorio de trabajo local creado: ${PROJECT_DIR_LOCAL}"

VARS_TO_SUBSTITUTE='$PROJECT_NAME_LOWER $DOCKERHUB_USERNAME $ODOO_SERVER_IP $ODOO_SERVER_USER $TRAEFIK_HOST $ODOO_WEB_PORT $ODOO_LONGPOLLING_PORT $DB_HOST $DB_PORT $DB_NAME $DB_USER $PROJECT_FULL_NAME'

envsubst "$VARS_TO_SUBSTITUTE" < ./templates/deploy.yml.template > "${PROJECT_DIR_LOCAL}/config/deploy.yml"
envsubst < ./templates/odoo.conf.template > "${PROJECT_DIR_LOCAL}/config/odoo.conf"

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
# --- CORRECCIÓN CLAVE ---
# Inyectamos las variables directamente en el script que se ejecuta remotamente.
# El comando `bash` remoto leerá este bloque de script completo.
ssh ${ODOO_SERVER_USER}@${ODOO_SERVER_IP} << EOF
  set -e
  # Definimos las variables dentro del script remoto.
  # El uso de 'cat << "EOT"' y 'EOT' previene la expansión de caracteres especiales.
  KEY_PATH="/root/.ssh/kamal_deploy_key"
  mkdir -p /root/.ssh
  cat << "EOT" > "\$KEY_PATH"
${ODOO_SERVER_SSH_KEY}
EOT
  chmod 600 "\$KEY_PATH"
  echo "Clave SSH para Kamal creada en el servidor."

  PROJECT_DIR_REMOTE="${PROJECT_DIR_REMOTE}"
  cd "\${PROJECT_DIR_REMOTE}"

  # Creamos el .env para los secretos que necesita Kamal.
  echo "DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}" > .env
  echo "ODOO_ADMIN_PASSWD=${ODOO_ADMIN_PASSWD}" >> .env
  echo "DB_PASSWORD=${DB_PASSWORD}" >> .env

  # Ejecutar Kamal
  kamal setup
  kamal env push
  kamal deploy
EOF

echo "✅ ✅ ✅ ¡DESPLIEGUE COMPLETADO EXITOSAMENTE! ✅ ✅ ✅"
echo "Instancia disponible en: https://${TRAEFIK_HOST}"
