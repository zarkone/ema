EMACS ?= emacs

test:
	$(EMACS) -Q --batch -L . -l ema-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . --eval "(setq byte-compile-error-on-warn nil)" -f batch-byte-compile ema-llm.el ema-tools.el ema-self.el ema-org.el ema.el ema-actions.el
	 rm -f *.elc

.PHONY: test compile
