#!/bin/bash
set -e

echo "🔍 Verificando dependências..."

# Atualiza repositórios
sudo dnf makecache

# Instala ansible-core, pip e make
echo "📦 Instalando ansible-core, pip e make..."
sudo dnf install -y ansible-core python3-pip make

# Atualiza pip
echo "📦 Atualizando pip..."
python3 -m pip install --upgrade pip --user

#instalando jmespath
python3 -m pip install jmespath

# Configurar AWS CLI
echo "🔧 Configurando AWS CLI..."

read -rp "📝 AWS Access Key ID: " aws_access_key
read -rsp "🔒 AWS Secret Access Key: " aws_secret_key
echo

read -rp "🌎 Região padrão (ex: us-east-2) [us-east-2]: " aws_region
aws_region=${aws_region:-us-east-2}

read -rp "📦 Formato de saída (ex: json) [json]: " aws_output
aws_output=${aws_output:-json}

aws configure set aws_access_key_id "$aws_access_key"
aws configure set aws_secret_access_key "$aws_secret_key"
aws configure set region "$aws_region"
aws configure set output "$aws_output"

# Verifica se a autenticação foi bem-sucedida
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS não autenticado. Verifique as credenciais fornecidas."
    exit 1
fi

# Instala as collections
echo "📚 Instalando collections kubernetes.core e amazon.aws..."
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install amazon.aws
ansible-galaxy collection install community.general

# Executa setup_tools
echo "⚙️ Executando setup_tools..."
make setup_tools

# Executa todas as etapas em sequência
echo "🚀 Iniciando provisionamento completo..."

echo "🌐 Criando cluster ROSA..."
make prepare

#echo "🔐 Criando usuário admin..."
#make deploy-admin

echo "📁 Criando machinepools..."
make create_machinepool

echo "⏳ Aguardando 10 minutos antes de aplicar projetos..."
sleep 600

echo "📦 Crie os projetos... make create_projects"

echo "⚙️ Migre as imagens entre os clusters ajuste o vars.yml e coloque os valores dos clusters e execute... make migrate_images"

echo "⚙️ Migre as aplicações entre os clusters executando... make migrate_applications"

echo "✅ Ambiente provisionado com sucesso!"
