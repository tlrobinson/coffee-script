module CoffeeScript

  # In order to keep the grammar simple, the stream of tokens that the Lexer
  # emits is rewritten by the Rewriter, smoothing out ambiguities, mis-nested
  # indentation, and single-line flavors of expressions.
  class Rewriter

    # Tokens that must be balanced.
    BALANCED_PAIRS = [['(', ')'], ['[', ']'], ['{', '}'], [:INDENT, :OUTDENT]]

    # Tokens that signal the start of a balanced pair.
    EXPRESSION_START = BALANCED_PAIRS.map {|pair| pair.first }

    # Tokens that signal the end of a balanced pair.
    EXPRESSION_TAIL  = BALANCED_PAIRS.map {|pair| pair.last }

    # Tokens that indicate the close of a clause of an expression.
    EXPRESSION_CLOSE = [:CATCH, :WHEN, :ELSE, :FINALLY] + EXPRESSION_TAIL

    # The inverse mappings of token pairs we're trying to fix up.
    INVERSES = BALANCED_PAIRS.inject({}) do |memo, pair|
      memo[pair.first] = pair.last
      memo[pair.last]  = pair.first
      memo
    end

    # Single-line flavors of block expressions that have unclosed endings.
    # The grammar can't disambiguate them, so we insert the implicit indentation.
    SINGLE_LINERS  = [:ELSE, "=>", "==>", :TRY, :FINALLY, :THEN]
    SINGLE_CLOSERS = ["\n", :CATCH, :FINALLY, :ELSE, :OUTDENT, :LEADING_WHEN]

    # Rewrite the token stream in multiple passes, one logical filter at
    # a time. This could certainly be changed into a single pass through the
    # stream, with a big ol' efficient switch, but it's much nicer like this.
    def rewrite(tokens)
      @tokens = tokens
      adjust_comments
      remove_leading_newlines
      remove_mid_expression_newlines
      move_commas_outside_outdents
      add_implicit_indentation
      ensure_balance(*BALANCED_PAIRS)
      rewrite_closing_parens
      @tokens
    end

    # Rewrite the token stream, looking one token ahead and behind.
    # Allow the return value of the block to tell us how many tokens to move
    # forwards (or backwards) in the stream, to make sure we don't miss anything
    # as the stream changes length under our feet.
    def scan_tokens
      i = 0
      loop do
        break unless @tokens[i]
        move = yield(@tokens[i - 1], @tokens[i], @tokens[i + 1], i)
        i += move
      end
    end

    # Massage newlines and indentations so that comments don't have to be
    # correctly indented, or appear on their own line.
    def adjust_comments
      scan_tokens do |prev, token, post, i|
        next 1 unless token[0] == :COMMENT
        before, after = @tokens[i - 2], @tokens[i + 2]
        if before && after &&
            ((before[0] == :INDENT && after[0] == :OUTDENT) ||
            (before[0] == :OUTDENT && after[0] == :INDENT)) &&
            before[1] == after[1]
          @tokens.delete_at(i + 2)
          @tokens.delete_at(i - 2)
          next 0
        elsif prev[0] == "\n" && [:INDENT].include?(after[0])
          @tokens.delete_at(i + 2)
          @tokens[i - 1] = after
          next 1
        elsif !["\n", :INDENT, :OUTDENT].include?(prev[0])
          @tokens.insert(i, ["\n", Value.new("\n", token[1].line)])
          next 2
        else
          next 1
        end
      end
    end

    # Leading newlines would introduce an ambiguity in the grammar, so we
    # dispatch them here.
    def remove_leading_newlines
      @tokens.shift if @tokens[0][0] == "\n"
    end

    # Some blocks occur in the middle of expressions -- when we're expecting
    # this, remove their trailing newlines.
    def remove_mid_expression_newlines
      scan_tokens do |prev, token, post, i|
        next 1 unless post && EXPRESSION_CLOSE.include?(post[0]) && token[0] == "\n"
        @tokens.delete_at(i)
        next 0
      end
    end

    # Make sure that we don't accidentally break trailing commas, which need
    # to go on the outside of expression closers.
    def move_commas_outside_outdents
      scan_tokens do |prev, token, post, i|
        if token[0] == :OUTDENT && prev[0] == ','
          @tokens.delete_at(i)
          @tokens.insert(i - 1, token)
        end
        next 1
      end
    end

    # Because our grammar is LALR(1), it can't handle some single-line
    # expressions that lack ending delimiters. Use the lexer to add the implicit
    # blocks, so it doesn't need to.
    # ')' can close a single-line block, but we need to make sure it's balanced.
    def add_implicit_indentation
      scan_tokens do |prev, token, post, i|
        next 1 unless SINGLE_LINERS.include?(token[0]) && post[0] != :INDENT &&
          !(token[0] == :ELSE && post[0] == :IF) # Elsifs shouldn't get blocks.
        line = token[1].line
        @tokens.insert(i + 1, [:INDENT, Value.new(2, line)])
        idx = i + 1
        parens = 0
        loop do
          idx += 1
          tok = @tokens[idx]
          if !tok || SINGLE_CLOSERS.include?(tok[0]) ||
              (tok[0] == ')' && parens == 0)
            @tokens.insert(idx, [:OUTDENT, Value.new(2, line)])
            break
          end
          parens += 1 if tok[0] == '('
          parens -= 1 if tok[0] == ')'
        end
        next 1 unless token[0] == :THEN
        @tokens.delete_at(i)
        next 0
      end
    end

    # Ensure that all listed pairs of tokens are correctly balanced throughout
    # the course of the token stream.
    def ensure_balance(*pairs)
      levels = Hash.new(0)
      scan_tokens do |prev, token, post, i|
        pairs.each do |pair|
          open, close = *pair
          levels[open] += 1 if token[0] == open
          levels[open] -= 1 if token[0] == close
          raise ParseError.new(token[0], token[1], nil) if levels[open] < 0
        end
        next 1
      end
      unclosed = levels.detect {|k, v| v > 0 }
      raise SyntaxError, "unclosed '#{unclosed[0]}'" if unclosed
    end

    # We'd like to support syntax like this:
    #    el.click(event =>
    #      el.hide())
    # In order to accomplish this, move outdents that follow closing parens
    # inwards, safely. The steps to accomplish this are:
    #
    # 1. Check that all paired tokens are balanced and in order.
    # 2. Rewrite the stream with a stack: if you see an '(' or INDENT, add it
    #    to the stack. If you see an ')' or OUTDENT, pop the stack and replace
    #    it with the inverse of what we've just popped.
    # 3. Keep track of "debt" for tokens that we fake, to make sure we end
    #    up balanced in the end.
    #
    def rewrite_closing_parens
      verbose = ENV['VERBOSE']
      stack, debt = [], Hash.new(0)
      stack_stats = lambda { "stack: #{stack.inspect} debt: #{debt.inspect}\n\n" }
      puts "rewrite_closing_original: #{@tokens.inspect}" if verbose
      scan_tokens do |prev, token, post, i|
        tag, inv = token[0], INVERSES[token[0]]
        # Push openers onto the stack.
        if EXPRESSION_START.include?(tag)
          stack.push(token)
          puts "pushing #{tag} #{stack_stats[]}" if verbose
          next 1
        # The end of an expression, check stack and debt for a pair.
        elsif EXPRESSION_TAIL.include?(tag)
          puts @tokens[i..-1].inspect if verbose
          # If the tag is already in our debt, swallow it.
          if debt[inv] > 0
            debt[inv] -= 1
            @tokens.delete_at(i)
            puts "tag in debt #{tag} #{stack_stats[]}" if verbose
            next 0
          else
            # Pop the stack of open delimiters.
            match = stack.pop
            mtag  = match[0]
            # Continue onwards if it's the expected tag.
            if tag == INVERSES[mtag]
              puts "expected tag #{tag} #{stack_stats[]}" if verbose
              next 1
            else
              # Unexpected close, insert correct close, adding to the debt.
              debt[mtag] += 1
              puts "unexpected #{tag}, replacing with #{INVERSES[mtag]} #{stack_stats[]}" if verbose
              val = mtag == :INDENT ? match[1] : INVERSES[mtag]
              @tokens.insert(i, [INVERSES[mtag], Value.new(val, token[1].line)])
              next 1
            end
          end
        else
          # Uninteresting token:
          next 1
        end
      end
    end

  end
end