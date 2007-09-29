require 'net/imap'

module Net
	class IMAP
		remove_const :BodyTypeBasic
    class BodyTypeBasic < Struct.new(:media_type, :subtype, :part_id,
                                     :param, :content_id,
                                     :description, :encoding, :size,
                                     :md5, :disposition, :language,
                                     :extension)
      def multipart?
        return false
      end

      # Obsolete: use +subtype+ instead.  Calling this will
      # generate a warning message to +stderr+, then return 
      # the value of +subtype+.
      def media_subtype
        $stderr.printf("warning: media_subtype is obsolete.\n")
        $stderr.printf("         use subtype instead.\n")
        return subtype
      end
    end

		remove_const :BodyTypeText
    # Net::IMAP::BodyTypeText represents TEXT body structures of messages.
    # 
    # ==== Fields:
    # 
    # lines:: Returns the size of the body in text lines.
    # 
    # And Net::IMAP::BodyTypeText has all fields of Net::IMAP::BodyTypeBasic.
    # 
    class BodyTypeText < Struct.new(:media_type, :subtype, :part_id,
                                    :param, :content_id,
                                    :description, :encoding, :size,
                                    :lines,
                                    :md5, :disposition, :language,
                                    :extension)
      def multipart?
        return false
      end

      # Obsolete: use +subtype+ instead.  Calling this will
      # generate a warning message to +stderr+, then return 
      # the value of +subtype+.
      def media_subtype
        $stderr.printf("warning: media_subtype is obsolete.\n")
        $stderr.printf("         use subtype instead.\n")
        return subtype
      end
    end

		remove_const :BodyTypeMessage
    # Net::IMAP::BodyTypeMessage represents MESSAGE/RFC822 body structures of messages.
    # 
    # ==== Fields:
    # 
    # envelope:: Returns a Net::IMAP::Envelope giving the envelope structure.
    # 
    # body:: Returns an object giving the body structure.
    # 
    # And Net::IMAP::BodyTypeMessage has all methods of Net::IMAP::BodyTypeText.
    #
    class BodyTypeMessage < Struct.new(:media_type, :subtype, :part_id,
                                       :param, :content_id,
                                       :description, :encoding, :size,
                                       :envelope, :body, :lines,
                                       :md5, :disposition, :language,
                                       :extension)
      def multipart?
        return false
      end

      # Obsolete: use +subtype+ instead.  Calling this will
      # generate a warning message to +stderr+, then return 
      # the value of +subtype+.
      def media_subtype
        $stderr.printf("warning: media_subtype is obsolete.\n")
        $stderr.printf("         use subtype instead.\n")
        return subtype
      end
    end
		
		remove_const :BodyTypeMultipart
    class BodyTypeMultipart < Struct.new(:media_type, :subtype, :part_id,
                                         :parts,
                                         :param, :disposition, :language,
                                         :extension)
      def multipart?
        return true
      end

      # Obsolete: use +subtype+ instead.  Calling this will
      # generate a warning message to +stderr+, then return 
      # the value of +subtype+.
      def media_subtype
        $stderr.printf("warning: media_subtype is obsolete.\n")
        $stderr.printf("         use subtype instead.\n")
        return subtype
      end
    end

    class ResponseParser # :nodoc:
      def body
        @lex_state = EXPR_DATA
        @partids ||= []
        token = lookahead
        if token.symbol == T_NIL
          shift_token
          result = nil
        else
          match(T_LPAR)
          token = lookahead
          if token.symbol == T_LPAR
            result = body_type_mpart
          else
            result = body_type_1part
          end
          match(T_RPAR)
        end
        @lex_state = EXPR_BEG
        return result
      end

      def body_type_basic
        mtype, msubtype = media_type
        token = lookahead
        if token.symbol == T_RPAR
          return BodyTypeBasic.new(mtype, msubtype, part_id)
        end
        match(T_SPACE)
        param, content_id, desc, enc, size = body_fields
        md5, disposition, language, extension = body_ext_1part
        return BodyTypeBasic.new(mtype, msubtype, part_id,
                                 param, content_id,
                                 desc, enc, size,
                                 md5, disposition, language, extension)
      end

      def body_type_text
        mtype, msubtype = media_type
        match(T_SPACE)
        param, content_id, desc, enc, size = body_fields
        match(T_SPACE)
        lines = number
        md5, disposition, language, extension = body_ext_1part
        return BodyTypeText.new(mtype, msubtype, part_id,
                                param, content_id,
                                desc, enc, size,
                                lines,
                                md5, disposition, language, extension)
      end

      def body_type_msg
        mtype, msubtype = media_type
        match(T_SPACE)
        param, content_id, desc, enc, size = body_fields
        match(T_SPACE)
        env = envelope
        match(T_SPACE)
				if msubtype =~ /delivery-status/i
					md5, disposition, language = nil, nil, nil
					extension = body_extensions
				else
					b = body
					match(T_SPACE)
					lines = number
					md5, disposition, language, extension = body_ext_1part
				end
        return BodyTypeMessage.new(mtype, msubtype, part_id,
                                   param, content_id,
                                   desc, enc, size,
                                   env, b, lines,
                                   md5, disposition, language, extension)
      end

      def body_type_mpart
        parts = []
        @partids.push 0
        while true
          @partids.push @partids.pop + 1
          token = lookahead
          if token.symbol == T_SPACE
            shift_token
            break
          end
          parts.push(body)
        end
        mtype = "MULTIPART"
        msubtype = case_insensitive_string
        param, disposition, language, extension = body_ext_mpart
        @partids.pop
        return BodyTypeMultipart.new(mtype, msubtype, part_id, parts,
                                     param, disposition, language,
                                     extension)
      end

			def part_id
				if @partids.empty?
					1
				else
					@partids.join('.')
				end
			end
    end
  end
end
