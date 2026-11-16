install:  ## Installe les outils de dev et les hooks pre-commit
	python -m pip install -e ".[dev]"
	pre-commit install

lint:  ## Vérifie le style et le formatage (ce que fait la CI)
	ruff check .
	ruff format --check .

format:  ## Corrige le style et reformate
	ruff check --fix .
	ruff format .

.PHONY: install lint format
