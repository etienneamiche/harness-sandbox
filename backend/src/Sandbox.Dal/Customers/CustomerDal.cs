using Npgsql;

namespace Sandbox.Dal.Customers;

public sealed record Customer(int Id, string Name, string Email);

public sealed class CustomerDal(NpgsqlDataSource db)
{
    public async Task<Customer?> FindByEmailAsync(string email, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("SELECT id, name, email FROM customers WHERE email = $1");
        cmd.Parameters.AddWithValue(email);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new Customer(reader.GetInt32(0), reader.GetString(1), reader.GetString(2))
            : null;
    }

    public async Task<IReadOnlyList<Customer>> ListAsync(int offset, int limit, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("SELECT id, name, email FROM customers ORDER BY id OFFSET $1 LIMIT $2");
        cmd.Parameters.AddWithValue(offset);
        cmd.Parameters.AddWithValue(limit);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var customers = new List<Customer>();
        while (await reader.ReadAsync(ct))
        {
            customers.Add(new Customer(reader.GetInt32(0), reader.GetString(1), reader.GetString(2)));
        }
        return customers;
    }
}
