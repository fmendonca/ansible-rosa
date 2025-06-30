
# Ansible ROSA Automation

Este projeto automatiza o provisionamento, configuração e migração de recursos entre clusters ROSA (Red Hat OpenShift Service on AWS) utilizando Ansible.

## Estrutura do Projeto

```
ansible-rosa/
├── Makefile                      # Atalhos para comandos comuns
├── env                          # Arquivo de ambiente
├── setup.sh                     # Script inicial para preparar dependências
├── shell/                       # Scripts auxiliares
│   ├── copy-image.sh
│   └── copy-image.sh.bkp
├── vars/                        # Variáveis globais do projeto
│   └── vars.yml
├── playbooks/                   # Playbooks principais do projeto
│   ├── create_machinepool.yml
│   ├── create_projects.yml
│   ├── deploy_rosa_cluster.yml
│   ├── install_gitops.yml
│   ├── migrate_resources.yml
│   └── setup_tools.yml
├── rosa_cluster_role/           # Role Ansible para criação de cluster ROSA
│   ├── defaults/
│   ├── tasks/
│   │   ├── create_cluster.yml
│   │   ├── main.yml
│   │   ├── post_create.yml
│   │   └── pre_create.yml
│   ├── templates/
│   │   └── kms-policy-initial.json.j2
│   └── vars/
│       └── main.yml
```

## Pré-requisitos

- Red Hat Enterprise Linux 8 ou 9
- Ansible 2.12+
- ROSA CLI
- AWS CLI configurado
- Python com dependências instaladas via `pip install -r requirements.txt` (se houver)

## Uso

### 1. Preparar o ambiente

```bash
./setup.sh
```

Instala o Ansible, ferramentas necessárias e configura o ambiente.

### 2. Criar cluster ROSA

```bash
ansible-playbook playbooks/deploy_rosa_cluster.yml
```

### 3. Instalar ferramentas auxiliares no cluster

```bash
ansible-playbook playbooks/setup_tools.yml
```

### 4. Criar MachinePool

```bash
ansible-playbook playbooks/create_machinepool.yml
```

### 5. Migrar recursos entre clusters

```bash
ansible-playbook playbooks/migrate_resources.yml
```

### 6. Criar projetos

```bash
ansible-playbook playbooks/create_projects.yml
```

## Observações

- O projeto inclui políticas de KMS (`kms-policy-initial.json.j2`) utilizadas durante a criação do cluster com criptografia personalizada.
- O shell script `copy-image.sh` pode ser utilizado para migração manual de imagens entre registries OpenShift.

## Licença

Este projeto é distribuído sob a licença MIT. Veja o arquivo `LICENSE` para mais informações.
