# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:audit_logs) do
      primary_key :id
      column :model_type,       String
      column :model_id,         String
      column :event,            String
      column :changed,          :jsonb
      column :workspace_id,     :int
      column :user_id,          :int
      column :username,         String
      column :user_type,        String, default: "User"
      column :created_at,       DateTime
      column :query,            String
      column :data,             :jsonb, default: Sequel.pg_jsonb({})

      index :created_at
      index %i[model_type model_id]
      index :user_id
      index :workspace_id
    end

    create_function(:audit_changes, <<~SQL, returns: :trigger, language: :plpgsql, replace: true)
      DECLARE
        changes jsonb := '{}'::jsonb;
        column_name text;
        n jsonb;
        o jsonb;
        __audit_info RECORD;
        model_id text;
        return_record RECORD;
        trid bigint;
      BEGIN
        SELECT txid_current() INTO trid;

        EXECUTE CONCAT(
          'SELECT * FROM __', TG_TABLE_SCHEMA, '_', TG_TABLE_NAME, '_audit_info_', trid::text
        ) INTO __audit_info;

        FOREACH column_name IN ARRAY __audit_info.columns
        LOOP
          IF (TG_OP = 'UPDATE') THEN
            EXECUTE 'SELECT to_jsonb(($1).' || column_name || ')' INTO n USING NEW;
            EXECUTE 'SELECT to_jsonb(($1).' || column_name || ')' INTO o USING OLD;
            IF (o != n) THEN
              SELECT changes || jsonb_build_object(column_name, ARRAY[o, n]) INTO changes;
            END IF;
          ELSE
            IF (TG_OP = 'DELETE') THEN
              EXECUTE 'SELECT to_jsonb(($1).' || column_name || ')' INTO n USING OLD;
            ELSIF (TG_OP = 'INSERT') THEN
              EXECUTE 'SELECT to_jsonb(($1).' || column_name || ')' INTO n USING NEW;
            END IF;
            SELECT changes || jsonb_build_object(column_name, n) INTO changes;
          END IF;
        END LOOP;

        CASE TG_OP
          WHEN 'UPDATE' THEN
            model_id := OLD.id;
            return_record := NEW;
          WHEN 'DELETE' THEN
            model_id := OLD.id;
            return_record := OLD;
          WHEN 'INSERT' THEN
            model_id := NEW.id;
            return_record := NEW;
          ELSE
            RAISE WARNING '[AUDIT.IF_MODIFIED_FUNC] - Other action occurred: %, at %',TG_OP,now();
            RETURN NULL;
        END CASE;
        INSERT INTO audit_logs ("model_type", "model_id", "event", "changed",
                                "created_at", "user_id", "username", "workspace_id", "query", "data")
        VALUES (coalesce(__audit_info.model_name::TEXT, TG_TABLE_NAME::TEXT), model_id, TG_OP,
                changes, NOW(), __audit_info.user_id, __audit_info.username, __audit_info.workspace_id, current_query(),
                __audit_info.data);
        RETURN return_record;
      END;
    SQL

    ### @TODO: Setup the trigger for all tables changes of you want to audit
    # execute <<~SQL
    #   CREATE TRIGGER audit_changes_on_table BEFORE INSERT OR UPDATE OR DELETE ON table
    #   FOR EACH ROW EXECUTE PROCEDURE audit_changes();
    # SQL
  end

  down do
    drop_function(:audit_changes, cascade: true)
    drop_table(:audit_logs)
  end
end
