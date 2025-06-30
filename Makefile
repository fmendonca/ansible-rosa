.PHONY: prepare deploy-admin clean setup_tools create_projects create_machinepool help check-env check-vars copy_images migrate_resources

# Variáveis comuns
VARS_FILE=vars/vars.yml
ANSIBLE_CMD=ansible-playbook -e @$(VARS_FILE)
PLAYBOOK_DIR=playbooks

help:
	@echo ""
	@echo "Comandos disponíveis:"
	@echo "  make prepare             -> Cria cluster ROSA"
	@echo "  make deploy-admin        -> Cria usuário admin e salva credenciais"
	@echo "  make clean               -> Remove arquivos temporários"
	@echo "  make setup_tools         -> Instala ferramentas e configurações iniciais"
	@echo "  make create_projects     -> Aplica projetos contidos em files/projects/"
	@echo "  make create_machinepool  -> Cria machinepools nas subnets privadas"
	@echo "  make copy_images	  -> Copia as imagens e imagestream"
	@echo "  make migrate_resources	  -> Copia todas as aplicações"
	@echo ""

check-vars:
	@test -f $(VARS_FILE) || (echo "❌ Arquivo $(VARS_FILE) não encontrado!" && exit 1)

check-env:
	@command -v rosa >/dev/null 2>&1 || (echo "❌ 'rosa' CLI não instalado." && exit 1)
	@command -v aws >/dev/null 2>&1 || (echo "❌ 'aws' CLI não instalado." && exit 1)
	@command -v ansible-playbook >/dev/null 2>&1 || (echo "❌ Ansible não instalado." && exit 1)
	@aws sts get-caller-identity >/dev/null 2>&1 || (echo "❌ AWS não autenticado." && exit 1)

prepare: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/deploy_rosa_cluster.yml

deploy-admin: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/create_admin_user.yml

clean:
	@rm -f /tmp/*-admin.json /tmp/kubeconfig /tmp/kms_arn.txt
	@echo "✔️ Arquivos temporários removidos."

setup_tools: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/setup_tools.yml

create_projects: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/create_projects.yml

create_machinepool: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/create_machinepool.yml

copy_images: check-env
	bash shell/copy-to-ecr.sh

migrate_resources: check-env check-vars
	@$(ANSIBLE_CMD) $(PLAYBOOK_DIR)/migrate_resources.yml
