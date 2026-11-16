EMACS ?= emacs

# In dependency order, leaves first; the same list as `ema--source-files'
# in ema-self.el.
SOURCES = ema-llm.el ema-tools.el ema-review.el ema-history.el ema-self.el \
          ema-org.el ema-cell.el ema-chat.el ema.el ema-actions.el

test:
	$(EMACS) -Q --batch -L . -l ema-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . --eval "(setq byte-compile-error-on-warn nil)" -f batch-byte-compile $(SOURCES)
	 rm -f *.elc

.PHONY: test compile
