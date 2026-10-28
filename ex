# 1. Functions in the actual execution order

First, remember that some functions run for each request, while others run only when SQLAlchemy needs them.

| Function                  | Input → processing → output                                                                             | When is it called?                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `_is_true(v)`             | Configuration value → checks whether it's true → `True` / `False`                                       | Inside `verify_token()`                                               |
| `verify_token()`          | Request header → checks or reads JWT → token payload dictionary, or development-mode fallback           | When FastAPI resolves this dependency                                 |
| `to_list(value)`          | String/list/empty value → converts it → Python list                                                     | Whenever another function calls it                                    |
| `_normalize_level(value)` | `"Shop Floor"` → normalizes text → `"shopfloor"`                                                        | Inside `get_scope()`                                                  |
| `get_scope(payload)`      | Token payload → looks up `UserProfile` and calculates allowed plants/SBUs/shopfloors → scope dictionary | Requested by `init_db()`                                              |
| `init_db(scope)`          | Scope dictionary → creates session and attaches permissions → database session (`db`)                   | When an endpoint requests `Depends(init_db)`                          |
| `scoped_models()`         | Registered models → detects recognized columns → model-to-column mapping                                | When the automatic filter or insert hook needs it; results are cached |
| `_plant_clause()`         | Model + columns + scope → builds plant/shopfloor condition → SQLAlchemy condition                       | Inside `_model_filter()`                                              |
| `_sbu_clause()`           | Model + columns + scope → builds an SBU condition → condition or `None`                                 | Inside `_model_filter()`                                              |
| `_model_filter()`         | Model + columns + scope → chooses conditions → condition or `None`                                      | Inside `add_scope_filter()`                                           |
| `add_scope_filter(state)` | Query state → attaches eligible filters → modified query                                                | Automatically before an eligible ORM query executes                   |
| `_child_criteria(plants)` | Allowed plant list → builds filters through parent records → child-table conditions                     | Inside the newer `add_scope_filter()`                                 |
| `stamp_plant()`           | New database object + session scope → fills a missing plant if eligible → updated object                | Before an ORM insert                                                  |
| `user_in_scope(u, scope)` | User profile + scope → checks whether the profile is permitted → `True` / `False`                       | Only where application code explicitly calls it                       |

These are the roles defined by your uploaded code.&#x20;

Data_Server(20261028-230322).py

Data_Server(20261028-230322).py

Data_Server(20261028-230322).py

Data_Server(20261028-230322).py



The normal request flow is:

`verify_token` → `get_scope` → `init_db` → endpoint query → `add_scope_filter` → database results.

The helper functions run when their parent function needs them. The event listeners are registered when the module loads; they do not filter queries until the relevant database event happens.

# 2. How does each access level work?

Think of the hierarchy like this:

Company admin

All permitted plants in the company

SBU admin

Plants associated with the SBU

Plant admin

All shopfloors in their plant(s)

Shopfloor admin

Only their permitted shopfloor(s)

Your `get_scope()` calculates access differently for each level:

| Access level | What `get_scope()` reads and calculates                                       |
| ------------ | ----------------------------------------------------------------------------- |
| Company      | Reads `company_code` or `company`, then finds matching plant codes in `Plant` |
| SBU          | Reads `sbu`, finds associated plants, and retains the SBU values              |
| Plant        | Reads `plant_code`                                                            |
| Shopfloor    | Reads `plant_code` and `shopfloor`, then looks up relevant workcenters        |

The important concept is that access level determines how the scope is calculated. It does not automatically filter every database table by every organizational field. The model's columns and filtering rules determine what happens next.

# 3. What if a table has all columns, some columns, or no columns?

This is your main doubt.

Your code does not say, "Every table must contain all four columns." Instead, `scoped_models()` detects whichever recognized columns actually exist.

Here is what your current code does:

| Columns on the table           | What the current filter can do                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `plant` only                   | Filter by permitted plant                                                                                    |
| `plant` + `shopfloor`          | Filter by plant, and by shopfloor for shopfloor-restricted users                                             |
| `plant` + `workcenter_code`    | Can use permitted workcenter codes when shopfloor-restricted and no shopfloor column exists                  |
| `plant` + `sbu`                | For an SBU user, combines the plant and SBU conditions with OR                                               |
| `sbu` only                     | Can apply an SBU condition when the caller has an SBU scope                                                  |
| `company` only                 | The current company fallback is ineffective because `scope["companies"]` is never populated by `get_scope()` |
| None of the recognized columns | No generic filter is generated, unless the table is covered by the explicit child-table rules                |

For example, suppose a shopfloor admin has plant P100 and shopfloor SMT.

If a table has both `plant` and `shopfloor`, your intended condition is:

```
WHERE plant = 'P100'
  AND shopfloor = 'SMT'
```

But if the table contains only `plant`, the current function falls back to:

```
WHERE plant = 'P100'
```

That is not the same permission. It can include records from other shopfloors in P100.

Also, if a table has both `plant` and `sbu`, your SBU condition is combined using `OR`, not `AND`. That may allow any row matching either condition, so you need to decide whether that behaviour matches your business rules.&#x20;

Data_Server(20261028-230322).py



# 4. Should you add plant, SBU, company and shopfloor columns to every table?

No. You do not need to duplicate all four columns in every table.

Choose the appropriate design for each kind of data.

| Type of table                                                | Recommended approach                                                                                     |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Main plant-specific records, such as PCBs                    | Store `plant_code`                                                                                       |
| Records that genuinely belong to one shopfloor or workcenter | Store the appropriate shopfloor/workcenter identifier, or reference the parent that contains it          |
| Child records, such as PCB process logs                      | Filter through their parent PCB or assignment using foreign keys                                         |
| Company and SBU information                                  | Usually obtain it through the plant/company relationship rather than duplicating it in every child table |

For example:

Plant table

| plant_code | company | sbu        |
| ---------- | ------- | ---------- |
| P100       | BEL     | Components |
| P200       | BEL     | Radar      |

PCB table

| pcb_serial | plant_code |
| ---------- | ---------- |
| PCB001     | P100       |
| PCB002     | P200       |

PCB process log

| pcb_serial | operation |
| ---------- | --------- |
| PCB001     | Cleaning  |
| PCB002     | Labelling |

The PCB table doesn't need to store company, SBU and shopfloor fields just to know its company. Its `plant_code` can identify the plant, and the Plant table can provide the company and SBU.

The process log can be restricted through the parent PCB, using the kind of subquery logic already present in `_child_criteria()`.

You only need additional fields when the record itself requires that information or your filtering strategy needs it. You do not need to rewrite all existing tables merely to copy values into extra columns.

One caution: your current insert hook, `stamp_plant()`, fills in a missing plant only when the user has exactly one permitted plant. For multi-plant users, the correct plant must be supplied and validated by the application.&#x20;

Data_Server(20261028-230322).py



## The one rule to remember

Every record that needs access control must have a reliable way to identify its organizational scope — either through its own columns or through its relationship to another record.

Your current code supports both approaches, but the direct-column filters and child-table filters do not cover every possible model. Missing scope information is not automatically inferred in every case, and some missing-column combinations can leave queries without the intended restrictions.

So don't start by adding four columns to every table. Start by deciding how each table is connected to a plant and, where necessary, to a shopfloor, then make the filtering logic follow that relationship.
