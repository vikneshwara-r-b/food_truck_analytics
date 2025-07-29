{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}

{% macro table_exists(schema_name, table_name) %}
    {% set relation = adapter.get_relation(
        database=target.database,
        schema=schema_name,
        identifier=table_name
    ) %}
    {{ return(relation is not none) }}
{% endmacro %}